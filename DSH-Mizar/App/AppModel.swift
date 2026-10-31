//
//  AppModel.swift
//  DSH-Mizar
//
//  The app's whole mutable state.
//
//  Deliberately one object rather than several: there is exactly one
//  connection, one pairing and one selected session at a time, and splitting
//  that across stores would only create questions about which one owns a
//  reconnect.
//

import Foundation
import Observation
import UserNotifications
import MizarKit

@MainActor
@Observable
final class AppModel {
    /// The one model this process has.
    ///
    /// `DSHMizarApp` used to construct it, which is one model per App value and
    /// therefore one model per launch -- the same thing, until a background
    /// launch. A `BGAppRefreshTask` can arrive before any view has appeared (and
    /// therefore before `RootView`'s `.task` has read the pairing), so the
    /// refresh needs a model that exists without a screen. See
    /// ``BackgroundRefresh``.
    static let shared = AppModel()

    /// Where the app is in its life: unpaired, connecting, or usable.
    enum Phase: Equatable {
        case launching
        case unpaired
        case connecting
        case ready
        case failed(String)
    }

    private(set) var phase: Phase = .launching
    /// The host this device is paired with, once known.
    private(set) var host: PairedHost?
    /// Every machine this phone is paired with, oldest pairing first.
    ///
    /// A list rather than one, because "one phone, one computer" was an assumption
    /// the first version made and it is the wrong one: somebody with a laptop
    /// and a desktop should not have to unpair one to reach the other.
    private(set) var hosts: [PairedHost] = []

    /// Which kind of host the one connection is to.
    ///
    /// The local agent is not a `PairedHost`: it has no token, no address to
    /// dial, nothing to forget and nothing to rename. What it does have is a
    /// `hostId` for the host-scoped caches, a session list and a connection --
    /// which is why it is a mode rather than a row in ``hosts``.
    enum HostMode: Equatable {
        case remote
        case local
    }

    private(set) var mode: HostMode = .remote

    /// The on-device agent, and the kernel behind it.
    ///
    /// Present from launch so the host list can ask it whether a model is
    /// configured; the kernel itself is not booted until it is picked (`start`
    /// is what boots it).
    let localAgent = LocalAgentController()

    /// Whether this connection is to the on-device agent.
    var isLocalAgentMode: Bool { mode == .local }

    /// The optional account: who is signed in, and what they have paid for.
    ///
    /// Optional in the product sense, not the Swift sense: every free feature
    /// works without it, and nothing here is consulted to decide whether the app
    /// may connect, sync or send. It exists for the relay's traffic identity and
    /// for the two screens that show it.
    let account: AccountController
    /// The Apple subscription, and the plan it changes on the server.
    let subscription: SubscriptionController
    /// The GitHub contributors shown in Settings, cached for a day.
    let credits = CreditsController()

    /// The machine whose pairing just completed and has not been named yet.
    ///
    /// Naming is offered once, right after pairing, when the operator knows
    /// which machine they just scanned. Asking later means asking about a row
    /// they can no longer identify.
    var pendingNameHostId: String?
    /// The host's own identity report, once connected.
    private(set) var welcome: WelcomeFrame?
    /// Which route the live connection is using, for the UI to show.
    ///
    /// Worth surfacing because the two behave differently under load: a relayed
    /// connection carries a round trip through another machine, and an operator
    /// wondering why everything feels slow deserves to see why.
    private(set) var activeEndpoint: PairedHost.Endpoint?

    /// Whether the live route reaches the computer on the operator's own
    /// network.
    ///
    /// True when the app is dialled directly at a non-loopback address: the
    /// operator's Wi-Fi, a tailnet, an mDNS name. Not true through the relay,
    /// and not true on loopback -- on a phone loopback never occurs, while on
    /// the simulator it is the fixture running on the same Mac, which is the
    /// one case where "local" would be an accident of the test rig rather than
    /// a fact about the operator's network.
    ///
    /// ### Why this is a product fact rather than a networking detail
    ///
    /// The relay is metered and the LAN is not, and the paid plan is three
    /// things the relay's bandwidth pays for: attachments, the running turn's
    /// full process detail, and the high-bandwidth relay server. On a LAN link
    /// the first two cost the project nothing, so they are unlocked for every
    /// account; see ``advancedFeaturesUnlocked``.
    var isLocalCommunication: Bool {
        #if DEBUG
        // A UI test drives the fixture over 127.0.0.1, which the rule above
        // deliberately excludes. The flag is how the LAN-unlocked UI stays
        // reachable from a test, and it exists only in Debug builds.
        if Self.launchForcesLocalNetwork { return true }
        #endif
        // The on-device agent moves no bytes across the relay at all -- it does
        // not even open a socket -- so the rule that unlocks the LAN features
        // unlocks them here by its own reason.
        if isLocalAgentMode { return true }
        return activeEndpoint?.isLocalNetwork ?? false
    }

    /// Whether the paid feature set is available: a paid account, or a link the
    /// relay is not carrying.
    ///
    /// Gates exactly the two features unlocked on a LAN link -- composer
    /// attachments and the running turn's full process detail. Everything else
    /// the app does was already free.
    var advancedFeaturesUnlocked: Bool {
        account.isPaid || isLocalCommunication
    }

    /// Whether the file preview may run.
    ///
    /// The preview is a paid-plan feature for the same reason attachments are:
    /// it moves the computer's bytes, and on a relay those bytes are the
    /// project's bandwidth. So it follows ``advancedFeaturesUnlocked`` exactly
    /// -- paid, or a LAN link where the relay carries nothing.
    ///
    /// The punched path is then excluded on top of that, for paid accounts too.
    /// A P2P direct link is not the operator's own network and not the
    /// metered relay either: it is the experimental route, and file transfer is
    /// deliberately not riding it yet. The switch in Settings says experimental;
    /// this is one of the places that means something.
    var previewUnlocked: Bool {
        // The on-device agent has no `file.stat`/`file.read` to serve a preview
        // from -- the kernel's tool surface reads its own workspace and nothing
        // else -- so the feature is off there whatever the plan says.
        !isLocalAgentMode
            && advancedFeaturesUnlocked
            && activeEndpoint?.isDirectPath != true
    }
    /// Which agent this phone opened on the computer, when it chose one.
    ///
    /// A computer runs three agents and they share nothing, so "the Mac's
    /// sessions" is not a thing: it is DSH's sessions, or Claude Code's, or
    /// Codex's. This is the choice, and everything the computer sends back is
    /// filtered by it -- the session list, the workspace list, and the picker
    /// that starts work.
    ///
    /// Read from two places, in this order of authority: the choice is stored on
    /// the pairing (so it survives a relaunch, which is the bug that made the
    /// list look random), and `host.info.engine` overwrites it, because a token
    /// the relay minted is scoped on the computer's side and that is what the
    /// arriving rows were actually filtered by. `nil` is "all agents" -- an older
    /// host, or a pairing nobody has chosen for yet.
    private(set) var engineScope: AgentEngine?

    /// The sessions the host lists, newest activity first.
    private(set) var sessions: [SessionRow] = [] {
        didSet {
            // Every read of the list goes through here -- the first download,
            // a manual refresh, the poll itself, the empty list a disconnect
            // leaves -- so this is the one place the running poll learns
            // whether it is still wanted. Starting it from a view instead is
            // how there ends up being one poll per screen.
            updateRunningPoll()
            // The same read is the one thing that says a held prompt's turn has
            // ended. A prompt is only ever held while a turn runs, so a row that
            // says it no longer does is the moment to hand it over.
            deliverHeldPromptsIfDue()
        }
    }

    /// Whether `sessions` is a list somebody actually gave.
    ///
    /// The difference between "the computer says nothing is running" and "this app has
    /// not asked yet", which is invisible in the array itself and decides whether
    /// the Live Activity may take a check down or start one. True once a stored
    /// index has been loaded or a `session.list` has come back, and false again
    /// when the machine is disconnected, because then the list is nobody's
    /// answer.
    private(set) var sessionsAreKnown = false

    /// The last thing that went wrong without being fatal.
    ///
    /// Separate from `phase`, and that separation is the fix for a real bug: a
    /// failed refresh used to set the whole app to `.failed`, so one dropped
    /// request looked exactly like the connection dying. Worse, the screen it
    /// landed on offered "Pair again", which forgot the pairing -- which is why
    /// a transient error could cost the operator their setup entirely.
    private(set) var lastError: String?

    /// Why the connection itself is down, when it is.
    ///
    /// One slot was not enough. A reconnect that fails writes the reason here,
    /// and the request that failed *because* the socket is gone then writes its
    /// own, smaller reason into ``lastError`` -- so the banner explained the
    /// computer by way of one dropped read. The connection's own sentence wins
    /// while the connection is down, because it is the one that is about the
    /// thing the operator is trying to fix.
    ///
    /// Cleared the moment a socket opens, so it cannot outlive its cause.
    private(set) var connectionError: String?

    /// The same failure as ``connectionError``, shaped for the sidebar's link
    /// bar: which devices to draw and which segment carries the cross.
    ///
    /// A second slot rather than parsing the sentence back: the sentence is
    /// written for a person and its wording is free to change, while the cross
    /// has to stay on the hop that actually failed. Both are written from the
    /// same ranked route, at the same moment, so they cannot disagree.
    private(set) var linkFailure: LinkStatus?

    /// Whether the relay said this account has spent its daily traffic.
    ///
    /// Set from the socket's close reason, because that is where the relay puts
    /// it: `1008 traffic allowance spent`. The alert is dismissible and stays
    /// down until the next close, so a reconnect loop cannot stack popups.
    var trafficNotice = false

    /// Whether `start()` has run. The login gate defers the first connect until
    /// somebody is signed in, and the view that does it may appear more than once.
    private var hasStarted = false

    /// The one first-connect task.
    ///
    /// Unstructured on purpose: a `.task` in a view is cancelled when that view
    /// goes away, and a pairing cancelled halfway lands on "Cannot reach the
    /// computer" with an empty reason -- which is exactly what a launch looked
    /// like whenever the root view re-laid out during the handshake. This task
    /// belongs to the model, not to a screen.
    private var startTask: Task<Void, Never>?

    /// Whether a reconnect is in flight, so the UI can say so.
    private(set) var reconnecting = false

    /// DSH's own title for a session, by id.
    ///
    /// Not in `session.list` -- the host assigns a title once a model has read
    /// the conversation, and it arrives with `session.stats`. Without it every
    /// row in a workspace showed the same string, because the workspace *is* the
    /// working directory: five sessions all reading "DSH-Mizar" tells you
    /// nothing about which is which.
    private(set) var titles: [String: String] = [:]

    /// The workspaces DSH has, as it last reported them.
    ///
    /// Kept because the session list cannot answer this on its own: a session
    /// outlives the workspace it was created in, so grouping sessions by their
    /// working directory draws a row for a workspace the operator deleted. From
    /// the machine this was reported from, DSH had 4 workspaces and the phone
    /// showed 10 — and every one of the ten was offered as a place to start a
    /// new session, which is the version of it that was reported twice.
    ///
    /// `nil` means the host has not said, and the screen falls back to grouping
    /// sessions on their working directory. An empty array means it said it has
    /// none, which is an answer and draws nothing. A failure here must never
    /// remove a workspace somebody is using, which is why the distinction is
    /// carried this far rather than collapsed into "no rows".
    private(set) var workspaces: [WorkspaceRow]?

    /// The session list, as sections.
    var workspaceGroups: [WorkspaceGroup] {
        WorkspaceCatalog.groups(
            sessions: sessions,
            workspaces: workspaces,
            selectedSessionId: selectedSessionId,
        )
    }

    /// Where a new session can be started.
    ///
    /// The host's workspaces, not the directories its sessions have happened to
    /// use: a deleted workspace leaves its session log behind, so the two are not
    /// the same list and the difference is exactly the report this answers.
    var workspaceChoices: [WorkspaceChoice] {
        WorkspaceCatalog.choices(sessions: sessions, workspaces: workspaces)
    }

    /// How many workspaces this phone is showing, in one line.
    ///
    /// In the refresh sheet, under the progress, because that is the number the
    /// operator can check against their computer without leaving the screen they are
    /// already on. The two cases are said differently on purpose: "the computer has
    /// not said" is not "zero", and the whole bug this answers came from those
    /// two being treated as the same thing.
    ///
    /// The conversations the host has no workspace for are counted on the same
    /// line, because they are a heading on the list above it: an operator
    /// comparing figures would otherwise find one section more than the number
    /// they were given, and conclude the count was wrong.
    var workspaceCountLine: String {
        guard let workspaces else { return String(localized: "Workspaces: the computer has not said") }
        let named = String(format: String(localized: "Workspaces: %lld"), workspaces.count)
        let unclaimed = workspaces.isEmpty
            ? 0
            : (workspaceGroups.first(where: \.isUnclaimed)?.sessions.count ?? 0)
        guard unclaimed > 0 else { return named }
        return named + String(format: String(localized: " · %lld not in a workspace"), unclaimed)
    }

    /// Fetch titles for sessions that do not have one yet.
    ///
    /// Concurrently, and only for the sessions actually on screen, because this
    /// is one request per session and a workspace can hold dozens.
    ///
    /// - Parameter sessionIds: the sessions to look up.
    func loadTitles(for sessionIds: [String]) async {
        let missing = sessionIds.filter { titles[$0] == nil }
        guard !missing.isEmpty, connection != nil else { return }
        // One at a time. A task group across the actor trips Swift 6's
        // region-based isolation checker, and the caller only ever asks for the
        // rows it is about to draw -- ten of them.
        var learned = false
        for sessionId in missing {
            guard let frame = await stats(for: sessionId) else { continue }
            if let title = frame.title, !title.isEmpty {
                titles[sessionId] = title
                learned = true
            }
        }
        // Titles are one request per session over a link that may not answer;
        // a title that has been learned once is kept, so the second visit to a
        // workspace is not a second round of requests that can fail.
        if learned { await persistIndex() }
    }

    /// What a sync is doing, or `nil` when none is.
    ///
    /// A refresh used to be a spinner with no end and no idea how far along it
    /// was, over a link that can be a phone on cellular. Saying which session of
    /// how many is the difference between waiting and wondering.
    private(set) var syncProgress: SyncProgress?

    /// How a sync is going.
    struct SyncProgress: Sendable, Equatable {
        /// What is being fetched.
        var current: String
        /// How many sessions are done.
        var completed: Int
        /// How many there are to do, or `0` while that is not known yet.
        var total: Int
        /// When this pass began, which is what an estimate is measured from.
        var startedAt: Date = Date()

        var fraction: Double { total == 0 ? 0 : Double(completed) / Double(total) }

        /// How much longer, once a rate can be measured at all.
        ///
        /// `nil` until at least one session has finished, and the restraint is
        /// the point: an estimate from no samples is not a small estimate, it is
        /// no estimate, and a countdown that starts at a made-up number and then
        /// changes is worse than a progress bar on its own.
        ///
        /// Measured per *session* rather than per byte, because the size of a
        /// conversation is not known before it is fetched and the number of them
        /// is.
        var remaining: TimeInterval? {
            guard completed > 0, total > completed else { return nil }
            let elapsed = Date().timeIntervalSince(startedAt)
            guard elapsed > 0 else { return nil }
            return (elapsed / Double(completed)) * Double(total - completed)
        }
    }

    /// Whether a sync is running.
    var isSyncing: Bool { syncProgress != nil }

    /// How far the running sync has got, for the button that started it.
    ///
    /// `nil` until the pass knows how many sessions it has: a ring filled to a
    /// made-up fraction is a ring that lies about where it is, and the glyph
    /// draws an unknown fraction as a turning arc instead.
    var syncFraction: Double? {
        guard let progress = syncProgress, progress.total > 0 else { return nil }
        return progress.fraction
    }

    /// How many automatic passes are on the socket.
    ///
    /// A counter, not a flag: a launch's first read can contain a reconnect,
    /// which runs a pass of its own, and the inner one finishing must not take
    /// the outer one's state with it.
    private var automaticRefreshes = 0

    /// Whether a pass nobody tapped is running -- a launch's first read, or the
    /// return to the foreground.
    ///
    /// The sidebar's refresh button reads this. Those passes are the app getting
    /// current by itself, and before this they were invisible: the button looked
    /// idle while a full read ran behind it, so a tap that the socket could not
    /// answer looked like a button that did nothing at all.
    var autoRefreshing: Bool { automaticRefreshes > 0 }

    /// Why the last sync produced nothing to report, when it did.
    ///
    /// The window that reports a refresh has a branch for "there is nothing
    /// running right now", and before this that branch said "Up to date. Every
    /// conversation on this computer is stored on this phone." -- which is a claim
    /// about the operator's data, made out of a request that was never sent.
    /// Tapping refresh with the computer unreachable said it.
    private(set) var syncProblem: String?

    /// Whether there is a stored session list for the current machine.
    ///
    /// This is what decides whether an unreachable computer is a dead end or a
    /// banner over data that is still here. The phone is opened on trains, in
    /// lifts and on the far side of a relay having a bad day, and a screen that
    /// replaces a conversation the operator already has with "cannot reach the
    /// computer" is a screen that threw away the answer to the question they opened
    /// it with.
    private(set) var hasStoredIndex = false

    /// The thing that is currently wrong, if anything.
    ///
    /// One accessor for two sources -- a failure of the connection itself and a
    /// request that did not land. It no longer has a banner of its own: the
    /// sidebar draws the connection as a picture (``linkStatus``) and lets
    /// request failures go to the log, so this is read where a sentence is still
    /// the right shape -- the failure screen, and a picker that has nothing else
    /// to say.
    var problem: String? {
        if let connectionError { return connectionError }
        if case .failed(let message) = phase { return lastError ?? message }
        return lastError
    }

    /// The sidebar's link bar, or `nil` when there is nothing to draw.
    ///
    /// Three facts, in this order: a dial that failed says which segment broke
    /// and which devices to draw; a live socket says which route it is on and
    /// that it is breathing; anything else is a dial in progress, drawn in the
    /// shape the pairing is most likely to land in.
    ///
    /// `nil` for the on-device agent (the frames never leave the process, so
    /// there is no link to draw) and for an unpaired phone (no devices at all).
    var linkStatus: LinkStatus? {
        guard !isLocalAgentMode, host != nil else { return nil }
        if let linkFailure { return linkFailure }
        let topology = activeEndpoint.map(Self.topology(of:))
            ?? LinkStatus.plannedTopology(for: host)
        if isConnected {
            return LinkStatus(
                topology: topology,
                connected: true,
                broken: nil,
                label: topology == .relay ? .connectedRelay : .connectedDirect,
            )
        }
        return LinkStatus(topology: topology, connected: false, broken: nil, label: .connecting)
    }

    /// Whether this pairing's first download is running.
    ///
    /// A flag rather than a second set of numbers: the full-screen view draws
    /// the same progress the sheet does, and two trackers would be two things to
    /// keep in step for no gain. `nil`-ing `syncProgress` between the phases of
    /// a sync is why this cannot simply be `syncProgress != nil`.
    private(set) var firstLoad = false
    /// Changes even when navigation leaves and later returns to the same id.
    private var selectionGeneration: UInt64 = 0
    /// The session the conversation screen is showing.
    var selectedSessionId: String? {
        didSet {
            guard selectedSessionId != oldValue else { return }
            selectionGeneration &+= 1
            // Dropped rather than kept: the cards on screen belong to the session
            // being left, and the read below is what puts this one's up.
            pendingState.clear()
            // The turn evidence belongs to the conversation that was open. The
            // list still says what it says, but a poll that was only up because
            // of the page the operator just left has nothing left to watch.
            openConversationTurnIsRunning = false
            updateRunningPoll()
            Task { await refreshInteractions() }
        }
    }
    /// Everything waiting on the operator right now.
    ///
    /// The host pushes `interactions.changed` the moment its pending set moves,
    /// so this is normally current within a round trip. The timer below is the
    /// safety net for a notification lost to a dropped socket, not the mechanism.
    ///
    /// Scoped to the machine it came from, and that is not bookkeeping: a
    /// question read on one computer and drawn under another is an approval card over
    /// a session that is not on this machine at all. It is the same defect the
    /// session screen had, one level up.
    private var pendingState = HostScoped<PendingInteractions>()

    /// See ``pendingState``.
    var pending: PendingInteractions? { pendingState.value(for: currentTag) }
    /// What each session was last told to use, so the picker can show it.
    ///
    /// Not persisted: it is a display of what this app asked for, and after a
    /// relaunch the plugin's own config is the truth. Showing a stale tick would
    /// be worse than showing none.
    private(set) var modelChoice: [String: ModelChoice] = [:]

    /// A provider, model and reasoning effort as chosen on this device.
    struct ModelChoice: Sendable, Equatable {
        let provider: String
        let model: String
        let effort: String?
    }

    /// The model the next session started from the home screen will use.
    ///
    /// The home pane is where a session is aimed before it exists, and the host's
    /// `session.create` takes no model -- so the choice is held here and applied
    /// between the create and the first prompt. See ``startSession(cwd:prompt:)``.
    ///
    /// Not persisted, for the same reason ``modelChoice`` is not: after a
    /// relaunch the plugin's own config is the truth. It does survive from one
    /// session to the next, because choosing a model is a preference about the
    /// work rather than about one conversation.
    private(set) var newSessionModel: ModelChoice?

    /// Choose the model for the next session.
    ///
    /// Nothing is sent. There is no session to send it to yet, and a call that
    /// pretended otherwise would be a switch reported as taken before it could
    /// be.
    ///
    /// - Parameters:
    ///   - provider: the provider id.
    ///   - model: the model id.
    ///   - effort: the reasoning level, or `nil` for the provider default.
    func chooseNewSessionModel(provider: String, model: String, effort: String?) {
        newSessionModel = ModelChoice(provider: provider, model: model, effort: effort)
    }

    /// The route this phone last had the host accept, in the kit's own shape.
    ///
    /// The composer bar and the model picker both name the route through this,
    /// so the button behind the sheet and the sheet itself cannot disagree.
    ///
    /// - Parameter sessionId: the session, or `nil` for the session the home
    ///   screen is about to start.
    /// - Returns: the accepted route, or `nil` when this phone has chosen nothing.
    func chosenModelSelection(for sessionId: String?) -> ModelSelection? {
        let choice: ModelChoice?
        if let sessionId {
            choice = modelChoice[sessionId]
        } else {
            choice = newSessionModel
        }
        guard let choice else { return nil }
        return ModelSelection(
            provider: choice.provider,
            model: choice.model,
            reasoningEffort: choice.effort,
        )
    }

    /// The models this host offers, and which host said so.
    ///
    /// Read once per connection and kept, so the machine it was read from is
    /// part of the value: switching computers used to draw the first computer's models in
    /// the second computer's picker, and the picker never asks again.
    private var modelCatalogState = HostScoped<ModelCatalog>()
    /// See ``modelCatalogState``.
    var modelCatalog: ModelCatalog? { modelCatalogState.value(for: currentTag) }
    /// The permission presets this host offers, and which host said so.
    private var permissionCatalogState = HostScoped<PermissionCatalog>()
    /// See ``permissionCatalogState``.
    var permissionCatalog: PermissionCatalog? { permissionCatalogState.value(for: currentTag) }
    /// The poll that watches for pending interactions.
    private var interactionPoll: Task<Void, Never>?
    /// The poll that follows a session while something is running.
    ///
    /// One task for the whole app, not one per screen. The bug it answers was
    /// reported with the conversation left open: a turn finished on the computer and
    /// the phone went on saying "DeepSeeking" until somebody pulled to refresh,
    /// because the only poll was the one after a send, which ends when the send
    /// settles. Views observe ``runningPollTicks``; none of them starts anything.
    private var runningPoll: Task<Void, Never>?
    /// The rules the task above is started and stopped by.
    ///
    /// A value rather than three separate `Bool`s because "is one already up"
    /// is part of the decision: a list read that still says a session is running
    /// must not reset the ten-second clock.
    private var runningPollState = RunningPoll()
    /// The rules that decide when a poll that cannot read should rebuild the
    /// socket.
    ///
    /// The poll is the only reader on a screen nobody has touched. Without this,
    /// a socket that died while the list says a turn is running left that row
    /// saying "running" until the operator pulled to refresh -- the next tick
    /// asked the same dead socket, and the one after that asked it again. See
    /// ``PollRecovery`` for why it takes two failures and waits thirty seconds.
    private var runningPollRecovery = PollRecovery()
    /// Whether the app is on screen, as far as the poll is concerned.
    ///
    /// False until the root view says otherwise, so a background launch -- a
    /// `BGAppRefreshTask` arrives before any scene -- does not start a poll that
    /// can only be suspended. Set from the `scenePhase` the app already watches.
    private var appIsActive = false
    /// Whether the conversation on screen holds a turn that has not ended.
    ///
    /// The second source the poll is allowed to start from, and the reason it
    /// needs one: after a send the app refreshes the *conversation* and never
    /// re-reads the session list, so the list can go on saying the session is
    /// not running while the operator is looking at the turn. This is what the
    /// screen is drawing, reported by the screen (see
    /// ``noteConversationTurns(_:for:)``); the list cannot overrule it until a
    /// read of the page says the turn has ended.
    private var openConversationTurnIsRunning = false
    /// Bumped after every running-poll tick.
    ///
    /// The view's half of the poll. The tick itself only knows about the model:
    /// the conversation's rows live in `@State` on the screen, so that screen has
    /// to be told a read has landed before it can re-read the cache. It observes
    /// this number and refreshes under its own single-flight lock; an integer
    /// rather than a callback so the model never holds a view.
    private(set) var runningPollTicks = 0

    // MARK: - Prompts held for the end of a turn

    /// Prompts the phone is keeping back, one per session.
    ///
    /// A send into a running turn with guided send off lands here instead of on
    /// the wire: the operator can still take it back, and the host's queue cannot
    /// be emptied once it has it. ``deliverHeldPromptsIfDue()`` is what hands it
    /// over once the turn ends, and the private methods below are the only
    /// writers -- so the bar, the delivery and the bytes on the socket cannot
    /// disagree about what is held.
    private(set) var pendingPrompts: [String: PendingPrompt] = [:]

    /// The last held prompt accepted by the host, per session.
    ///
    /// Consumed by the conversation screen (``acknowledgeDeliveredPrompt(_:)``)
    /// so it can draw the sent message and follow it down before the read-back
    /// has caught up. A delivery is a moment, not a state, which is why the
    /// screen takes it rather than reading a bool.
    private(set) var deliveredPrompts: [String: DeliveredPrompt] = [:]

    /// The automatic hand-over going on for a session, if one is.
    ///
    /// One task per session, kept so it can be cancelled when the operator takes
    /// the prompt back or throws it away, and so a sleeping retry cannot be
    /// joined by a second one.
    private var heldDeliveries: [String: HeldDelivery] = [:]

    /// Sessions with a hand-over in flight right now.
    ///
    /// The bar's send button and the automatic delivery both end up in
    /// ``deliverHeldPrompt(sessionId:as:)``; this is what keeps a tap during the
    /// automatic one from sending the same text twice. A duplicate prompt would
    /// not be a duplicate request to the host -- every send carries a fresh
    /// `requestId` -- it would be two real messages.
    private var deliveringHeldPrompts: Set<String> = []

    /// How many times an automatic hand-over retries before leaving the prompt
    /// in the bar for the operator.
    ///
    /// A failure here is usually the connection, and one retry is what covers
    /// the blip. Past that the bar is the honest answer: the text is still
    /// there, and the send button is one tap away.
    private static let heldDeliveryAttempts = 3

    /// A running automatic hand-over: the task and the token that owns the
    /// dictionary entry.
    private struct HeldDelivery {
        let token: UUID
        let task: Task<Void, Never>
    }
    /// The task consuming host-pushed events.
    private var eventListener: Task<Void, Never>?
    /// The resident task that asks the local network whether the computer is on
    /// it. See ``lanWatchTick()``.
    ///
    /// Alive only while the app is on screen: iOS suspends the process in the
    /// background, so a timer there would wake to find itself frozen rather than
    /// useful. Nothing here touches the screen -- the switch it makes is the same
    /// one a manual refresh makes, and its record is the log.
    private var lanWatch: Task<Void, Never>?

    /// Host events that mean the pending set moved.
    ///
    /// `interactions.changed` covers every case on its own, and the four
    /// specific names are listed because they predate it: a host built before
    /// the summary frame existed sends only those, and a client that ignored
    /// them would fall back to the slow timer for no reason.
    private static let interactionEvents: Set<String> = [
        "interactions.changed",
        "approval.request",
        "approval.resolved",
        "question.request",
        "question.resolved",
    ]

    /// How often to re-read pending interactions when nothing has been pushed.
    ///
    /// Deliberately slow. The host announces changes, so a short interval would
    /// be pure traffic; this only exists so that a notification lost to a
    /// reconnect cannot leave a card on screen that no longer exists.
    private static let interactionPollSeconds: Duration = .seconds(45)

    private let credentials: any CredentialStore
    /// Conversations kept on the phone, so history survives a lost network.
    let conversations: any ConversationCache
    /// The session list, its titles and the workspaces, kept on the phone.
    ///
    /// Separate from `conversations` because it answers a different question.
    /// The two are written at different moments and fail differently: a
    /// conversation that will not load is a screen with no messages, an index
    /// that will not load is a list with no rows.
    private let indexStore: any SessionIndexStore

    /// What the operator has switched on, and where it is written.
    ///
    /// The same object the notification delegate reads (`AppSettings.shared`) and
    /// the Live Activity is meant to read, which is what makes a switch on the
    /// settings screen change behaviour rather than only a picture of it.
    let settings: AppSettings

    /// The activity log the export button hands over.
    let log: ActivityLog

    /// The Live Activity: what the island shows, and when it comes down.
    ///
    /// Owned here rather than created by whichever screen happens to be open,
    /// because the moments that change its answer have nothing to do with the
    /// screens: a session list arriving, a conversation being folded into the
    /// cache, the app coming back to the foreground, and a switch moving on the
    /// settings tab.
    let liveActivity: LiveActivityController

    /// The observer that turns a new Live Activity push token into a registration.
    ///
    /// The activity's token is issued *after* the request that starts it, so the
    /// `push.register` sent when the socket opened usually predates it. This is
    /// what sends a second registration carrying it -- and the same call clears it
    /// on the host when the card comes down, because that registration omits the
    /// field.
    ///
    /// Registered here rather than from a view's `.onReceive`, unlike the device
    /// token: a background launch (a `BGAppRefreshTask` before any scene has
    /// appeared) can start an activity and obtain its token with no `RootView` in
    /// existence, and a token that waits for the next time somebody opens the app
    /// is a card that cannot be ended remotely until then.
    @ObservationIgnored private var liveActivityTokenObserver: (any NSObjectProtocol)?

    /// The observer on the push-to-start token.
    ///
    /// Registered beside the one above and for the same reason: the token is
    /// issued by the system on its own schedule, and the registration has to
    /// follow it whenever it appears.
    @ObservationIgnored private var liveActivityStartTokenObserver: (any NSObjectProtocol)?

    /// The archive the last successful export produced.
    ///
    /// Kept so the screen can keep saying that it happened, with the file's name
    /// and size: a share sheet that has been dismissed leaves no other trace, and
    /// "did that work?" is not a question the operator should have to answer by
    /// trying again.
    private(set) var lastLogExport: LogArchive?

    /// The host events that have arrived, newest first.
    ///
    /// Bounded, and it holds names rather than payloads: this exists for the log
    /// export, and what it has to answer is "did the host tell us anything, and
    /// when" -- not what it said.
    private var recentHostEventState = HostScoped<[HostSummary.Event]>()
    /// See ``recentHostEventState``.
    var recentHostEvents: [HostSummary.Event] { recentHostEventState.value(for: currentTag) ?? [] }

    /// The same events for the log export.
    ///
    /// Read through ``HostScoped/held`` rather than through the current tag,
    /// because the archive is built after the socket may already be gone: it
    /// describes what this phone holds, and reading it for a subject that no
    /// longer exists would report an empty history for a phone that has one.
    /// This is the accessor ``HostScoped`` has a `held` for.
    private var recentHostEventsForArchive: [HostSummary.Event] { recentHostEventState.held ?? [] }

    /// Official DSH wallets are distinct from the Mizar relay subscription account.
    let deepSeekBalance = DeepSeekBalanceController()
    var balanceConnectionTag: HostTag? {
        // A wallet belongs to the computer's DeepSeek account. The on-device
        // agent has no computer and no DSH install behind it, so there is no
        // wallet to read rather than a wallet reading zero.
        guard !isLocalAgentMode else { return nil }
        return phase == .ready ? currentTag : nil
    }

    func refreshDeepSeekBalance() async {
        guard let connection, let tag = balanceConnectionTag else {
            deepSeekBalance.configure(tag: nil)
            return
        }
        if deepSeekBalance.connectionTag != tag {
            deepSeekBalance.configure(
                tag: tag,
                readHost: { try await connection.call("host.info", as: HostInfo.self) },
                readBalance: {
                    try await connection.call(
                        "account.balance",
                        payload: .object(["client": .object([
                            "version": .string(Self.appVersion),
                            "locale": .string(Locale.current.identifier),
                            "timezoneOffsetSeconds": .number(Double(TimeZone.current.secondsFromGMT())),
                        ])]),
                        as: DeepSeekBalanceResponse.self,
                    )
                },
            )
        }
        await deepSeekBalance.refresh()
    }

    /// What the host says one session is doing, if it says anything.
    ///
    /// Reads through to the connection's state channel: `nil` when the host
    /// predates it or has the channel switched off, which the UI draws as
    /// nothing at all rather than as an unknown state.
    func liveState(for sessionId: String) async -> (state: SessionState?, stale: Bool, text: String)? {
        guard let connection else { return nil }
        let state = await connection.sessionState(sessionId)
        guard state != nil else { return nil }
        let stale = await connection.isStateStale(sessionId)
        let text = await connection.streamedText(sessionId)
        return (state, stale, text)
    }

    private var connection: MizarConnection? {
        didSet {
            if connection !== oldValue { deepSeekBalance.configure(tag: nil) }
            // Stamped here, the one place every socket passes through, so "how
            // long has this been up" cannot disagree with the socket in use.
            if connection == nil {
                connectedSince = nil
            } else if connection !== oldValue {
                connectedSince = Date()
                latencySamples = []
            }
        }
    }

    /// How many sockets this run has opened.
    ///
    /// Half of ``HostTag``. The host id says *which computer* a value is about; this
    /// says *which conversation with it*. Both halves matter: a read started over
    /// a socket that has since been replaced was answered by a host the app is no
    /// longer talking to, and a host id alone cannot tell that from the same
    /// machine still answering.
    private var nextConnectionEpoch = 0

    /// Which socket is open now, as an epoch, or `0` when none is.
    ///
    /// Kept here rather than derived from the connection object: a tag is
    /// compared and never dereferenced, so nothing may depend on the socket
    /// still being alive to answer a question about itself.
    private var connectionEpoch = 0

    /// The subject every host-scoped value is read and written for.
    ///
    /// `nil` when nothing is connected, which is deliberate: with no connection
    /// there is no subject, so nothing scoped can be read and nothing scoped can
    /// be written. Every one of these values is an answer from a host, and a host
    /// that is not connected has not answered.
    private var currentTag: HostTag? {
        guard connection != nil else { return nil }
        // The on-device agent has no pairing to read a host id from. Its id is
        // the mode itself: one stable name on this phone, for the life of the
        // install, in the same namespace the paired machines use.
        if isLocalAgentMode { return HostTag(hostId: Self.localHostId, epoch: connectionEpoch) }
        guard let hostId = host?.hostId else { return nil }
        return HostTag(hostId: hostId, epoch: connectionEpoch)
    }

    /// The id host-scoped caches are filed under while the on-device agent is
    /// connected. Never sent anywhere; it only has to be stable and not collide
    /// with a pairing.
    static let localHostId = "local-kernel"

    init(
        credentials: any CredentialStore = KeychainCredentialStore(),
        conversations: any ConversationCache = FileConversationCache(),
        index: any SessionIndexStore = FileSessionIndexStore(),
        settings: AppSettings = .shared,
        log: ActivityLog = .shared,
        accountStore: any AccountStoring = KeychainAccountStore(),
        accountClient: AccountClient? = nil,
        subscriptionStore: (any SubscriptionStore)? = nil,
    ) {
        self.credentials = credentials
        self.conversations = conversations
        self.indexStore = index
        self.settings = settings
        self.log = log
        let account = AccountController(store: accountStore, client: accountClient)
        let subscription = SubscriptionController(store: subscriptionStore)
        self.account = account
        self.subscription = subscription
        self.liveActivity = LiveActivityController(settings: settings, log: log)
        // The Live Activity's token, as the controller obtains and forgets it.
        // `queue: .main` is the delivery this observer needs -- the notification is
        // posted from the main actor's own ActivityKit path -- and the `Task` is
        // what lets the registration itself be the async call it is.
        liveActivityTokenObserver = NotificationCenter.default.addObserver(
            forName: LiveActivityPushTokenStore.changed,
            object: nil,
            queue: .main,
        ) { [weak self] _ in
            Task { await self?.syncPushRegistration() }
        }
        // The other token the registration carries, and the one that arrives
        // earliest: the push-to-start token is issued after a launch, possibly
        // before any card exists, so the registration that was made on connect
        // is nearly always the one that has to be repeated.
        liveActivityStartTokenObserver = NotificationCenter.default.addObserver(
            forName: LiveActivityStartTokenStore.changed,
            object: nil,
            queue: .main,
        ) { [weak self] _ in
            Task { await self?.syncPushRegistration() }
        }
        // The account owns nothing about the connection, and the connection owns
        // nothing about the account -- these two closures are the whole contract
        // between them. Signing in or out changes the relay identity headers,
        // and a header cannot be changed on a live socket, so that is a redial.
        // A successful sign-in also asks the App Store what it already holds, so
        // a subscription bought on another phone lands on this one.
        subscription.attach(to: account)
        account.onIdentityChange = { [weak self] in
            self?.accountIdentityChanged()
        }
        account.onAuthenticated = { [weak self] in
            await self?.subscription.syncEntitlements()
            await self?.subscription.load()
        }
        // The plan decides which relay the host's tunnel should use. A change
        // in either direction asks the host to move; the phone then updates the
        // base URL it stores and, if it is on the relay now, redials.
        account.onPlanChange = { [weak self] in
            self?.accountPlanChanged()
        }
    }

    /// Read what this phone already knows and make the island match it.
    ///
    /// The single entry point to the Live Activity, called from the four moments
    /// that can change its answer. It decides nothing itself: the decision layer
    /// in `MizarKit` says what to show, and ``LiveActivityController`` puts that
    /// on screen -- including the case where the operator has switched the whole
    /// feature off, which is read at the moment of acting rather than remembered
    /// from when an activity started.
    func refreshLiveActivity() async {
        // The island belongs to a computer: it is fed by that computer's pushes
        // and by background refreshes that can reach it. The on-device agent has
        // neither, so there is nothing to keep true and a card left over is
        // taken down instead.
        if isLocalAgentMode {
            await liveActivity.endForLocalAgent()
            return
        }
        await liveActivity.refresh(
            sessions: sessions,
            conversations: conversations,
            sessionsAreKnown: sessionsAreKnown,
            titles: titles,
            approvals: (pending?.approvals ?? []).map { approval in
                LiveActivityApproval(
                    requestId: approval.requestId,
                    sessionId: approval.sessionId ?? "",
                    tool: approval.toolName,
                    detail: approval.reasonText(preferring: Locale.preferredLanguages.first ?? "en") ?? "",
                )
            },
        )
    }

    // MARK: - Off screen

    /// When the background refresh now running runs out of time, if one is.
    ///
    /// Set by ``backgroundRefresh(expiresAt:reason:)`` and read by the repair a
    /// sync may start after its page. That repair issues extra requests, and the
    /// background contract is that **every** request is preceded by a
    /// ``BackgroundSync/mayStartRequest(now:expiresAt:)`` check. A foreground
    /// sync leaves this `nil` and asks no such question.
    ///
    /// The scope is the whole app rather than the one call: a foreground repair
    /// that happens to interleave with the tail of a background refresh is
    /// checked against that refresh's deadline too. That is conservative -- it
    /// can settle a turn instead of fetching it, and never overruns the
    /// assertion -- and the overlap is one request wide at most.
    private var backgroundDeadline: Date?

    /// One short refresh, run while the app is not on screen.
    ///
    /// Called from the two things iOS lends an app for this: the assertion taken
    /// when the app is backgrounded, and a `BGAppRefreshTask` (see
    /// ``BackgroundRefresh``). It exists for the island and for nothing else.
    ///
    /// What a refresh buys is a **change**, not the clock. The running turn's
    /// figure is seeded from the instant the host said the turn began, so a row
    /// already on the card tells the right time without being asked again; what
    /// goes stale is which sessions are running, what the operator last asked
    /// them, and whether the turn still is. So the sync reads the session list,
    /// then re-reads the page of each session that is running -- the same two
    /// sources ``LiveActivityController`` derives its rows from -- and lets the
    /// controller decide and send.
    ///
    /// Every request is preceded by ``BackgroundSync/mayStartRequest(now:expiresAt:)``,
    /// and there is no retry of anything that fails: an assertion spent retrying
    /// a computer that is asleep is an assertion that did not refresh what was
    /// running. Whatever arrived is applied; whatever did not is left for the
    /// next foreground, which is the retry the controller already documents.
    ///
    /// **What this cannot do.** It cannot make an activity appear on a phone
    /// whose app has not been opened since the session started. Apple's contract
    /// is that an activity is started from the foreground; the controller still
    /// attempts the start when it finds nothing on screen, because "does a
    /// background start work" is a question only a measurement answers, and the
    /// attempt is logged with the app state it was made in. The supported way is
    /// push-to-start, which this app does not have -- see
    /// ``BackgroundRefresh``'s header.
    ///
    /// - Parameters:
    ///   - expiresAt: when the app's background time runs out. Read before each
    ///     request, so the sync stops starting work with
    ///     ``BackgroundSync/requestReserve`` to spare.
    ///   - reason: what woke it, for the log: "entering the background" or "a
    ///     background refresh".
    /// - Returns: one line for the log: what was refreshed, and how long it took.
    @discardableResult
    func backgroundRefresh(expiresAt: Date, reason: String) async -> String {
        let started = Date()
        // Every request this refresh causes has to pass the budget check, and a
        // repair inside `syncConversation` is a request too -- see
        // ``repairStaleRunningTurns(for:)``.
        backgroundDeadline = expiresAt
        defer { backgroundDeadline = nil }
        guard host != nil else {
            return "background sync (\(reason)): nothing to do, this phone is not paired"
        }
        guard settings.values.liveActivitiesEnabled else {
            return "background sync (\(reason)): skipped, the Live Activity is switched off"
        }
        var refreshed = 0
        if connection != nil, BackgroundSync.mayStartRequest(now: started, expiresAt: expiresAt) {
            await refreshSessions(reconnectingIfNeeded: false)
        } else if connection == nil {
            log.add(
                .sync,
                "background sync (\(reason)): not connected; the island will be drawn from what is stored",
            )
        } else {
            log.add(
                .sync,
                "background sync (\(reason)): less than \(Int(BackgroundSync.requestReserve)) s left; the session list was not read",
            )
        }
        let targets = BackgroundSync.conversationRefreshTargets(in: sessions)
        for sessionId in targets {
            guard BackgroundSync.mayStartRequest(now: Date(), expiresAt: expiresAt) else { break }
            await syncConversation(for: sessionId)
            // Counted only when the read came back: a request the expiration
            // handler cancelled is reported as "failed" by the connection, and
            // a log line that called that refresh would make the one number the
            // report has into a claim the app cannot keep.
            if !Task.isCancelled, conversationError == nil { refreshed += 1 }
        }
        guard !Task.isCancelled else {
            // A cancelled refresh has no business sending anything: the app has
            // either come back or run out of time, and both mean the state the
            // controller would send is about to be replaced.
            return "background sync (\(reason)): out of time after \(refreshed) of \(targets.count) session(s); the island was left as it was"
        }
        await refreshLiveActivity()
        let took = Date().timeIntervalSince(started)
        return String(
            format: "background sync (%@): %d of %d session(s) refreshed in %.0f ms",
            reason,
            refreshed,
            targets.count,
            took * 1000,
        )
    }

    /// 实时活动 — whether the Live Activity may run.
    ///
    /// **The single place the Live Activity consults.** Whoever builds it should
    /// read this property at the moment it starts an activity, updates one or
    /// ends one, and should not keep a copy: this is a value the operator can
    /// change while an activity is on screen, and a cached answer is a switch
    /// that takes effect at the next launch.
    ///
    /// The app decides nothing else about it. Whether an activity is *running* is
    /// a fact about the activity, not about this preference, and conflating the
    /// two is how a switch ends up unable to say "no" to something already up.
    var liveActivitiesEnabled: Bool { settings.values.liveActivitiesEnabled }

    /// Whether a connection to the host is open right now.
    var isConnected: Bool { connection != nil }

    // MARK: - Vitals

    /// When the socket in use was opened, or `nil` while there is none.
    private(set) var connectedSince: Date?
    /// Round trips to the host, in milliseconds, oldest first and at most
    /// ``latencyHistory`` of them -- measured with `ping` only while somebody
    /// is looking at them, so a phone in a pocket sends nothing.
    private(set) var latencySamples: [Double] = []
    /// When the running poll last read the session list.
    private(set) var lastPollTickAt: Date?
    /// How many round trips are kept for the connection window's trace.
    static let latencyHistory = 24

    /// The last weeks of work, as the home page charts them, or `nil` until the
    /// host has answered once.
    ///
    /// One read per opening and per refresh rather than a live subscription:
    /// this is a picture of the past, and a picture that redraws itself while
    /// somebody is looking at it is a picture they cannot finish reading.
    private(set) var usageOverview: UsageOverview?
    /// Whether that read is on the socket.
    private(set) var usageLoading = false

    /// Read the usage history for the home page, from every computer the
    /// account knows.
    ///
    /// One read per computer rather than one per app: a phone is open on one
    /// machine at a time, but "how much did I get done" is a question about all
    /// of them, and a chart that only counts the machine the phone happens to be
    /// pointed at would be wrong every time the operator opened the app on the
    /// other one.
    ///
    /// The reads are sequential and each one is bounded by its own handshake
    /// timeout, so a computer that is asleep costs the page one attempt rather
    /// than a stalled refresh. Silent on failure: the chart keeps the last
    /// picture it had, and the connection window is where a link problem is
    /// reported.
    func loadUsageOverview() async {
        guard !usageLoading else { return }
        usageLoading = true
        defer { usageLoading = false }

        var readings: [UsageOverview] = []

        // The computer this phone is already open on, over the socket it has.
        if let connection,
           let overview = try? await connection.call("usage.overview", as: UsageOverview.self) {
            readings.append(overview)
        }

        // Every other computer the account knows, one at a time. A phone has
        // one socket's worth of attention, and holding three open to read a
        // chart is a cost the chart cannot justify.
        for desktop in account.desktops
        where desktop.online && desktop.deviceId != host?.deviceId {
            if let overview = await usageOverview(of: desktop) {
                readings.append(overview)
            }
        }

        guard !readings.isEmpty else { return }
        usageOverview = UsageOverview.merged(readings)
    }

    /// One computer's usage, over a socket of its own that is closed again.
    ///
    /// - Parameter desktop: the computer, as the account lists it.
    /// - Returns: what it answered, or `nil` when it did not.
    private func usageOverview(of desktop: AccountDesktop) async -> UsageOverview? {
        guard let relay = URL(string: RelayTier.paidBaseURL),
              let granted = try? await account.connect(to: desktop, engine: nil)
        else { return nil }
        let baseURL = relay
            .appendingPathComponent("r")
            .appendingPathComponent(granted.room)
            .absoluteString
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let temporary = PairedHost(
            hostId: desktop.deviceId,
            hostName: desktop.name,
            authority: nil,
            deviceId: desktop.deviceId,
            deviceToken: granted.token,
            baseURL: baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL,
        )
        let connection = makeConnection(host: temporary, endpoint: .relay(baseURL: temporary.baseURL ?? baseURL))
        defer { Task { await connection.disconnect() } }
        do {
            _ = try await connection.connect()
            return try await connection.call("usage.overview", as: UsageOverview.self)
        } catch {
            return nil
        }
    }

    /// Whether the poll that follows a running turn is up.
    var runningPollIsActive: Bool { runningPoll != nil }
    /// How often it asks.
    ///
    /// Ten seconds on a relayed link -- the interval exists because of the
    /// relay's bandwidth -- and three on the operator's own network, where the
    /// cost is nothing and a turn ending should be seen while the operator is
    /// still watching. See ``RunningPoll/localInterval``.
    ///
    /// While a prompt is held for the end of the turn it is three either way:
    /// that tick is the delay between the answer finishing and the operator's
    /// message going, and ten seconds of it reads as a send that did not happen.
    /// See ``RunningPoll/heldPromptInterval``.
    var runningPollInterval: Duration {
        if !pendingPrompts.isEmpty { return RunningPoll.heldPromptInterval }
        return isLocalCommunication ? RunningPoll.localInterval : RunningPoll.interval
    }
    /// Ticks in a row that could not read; the poll rebuilds the socket after two.
    var runningPollFailures: Int { runningPollRecovery.failures }
    /// Whether the host's pushed events are being listened to.
    var listensForHostEvents: Bool { eventListener != nil }
    /// How often pending requests are re-read when nothing has been pushed.
    var interactionFallbackInterval: Duration { Self.interactionPollSeconds }

    /// Measure one round trip to the host.
    ///
    /// `ping` is the cheapest frame the host answers -- it is answered before
    /// any method lookup -- so what is measured is the link, not the host's
    /// work. Not written to the activity log: it is asked every couple of
    /// seconds while the connection window is open, and a log of pings would
    /// bury the requests worth reading.
    ///
    /// - Returns: the round trip in milliseconds, or `nil` when there is no
    ///   socket or it did not answer.
    @discardableResult
    func measureLatency() async -> Double? {
        guard let connection else { return nil }
        let started = ContinuousClock.now
        do {
            _ = try await connection.call("ping", as: PingResult.self)
        } catch let error as MizarError where error.code == "EMPTY_RESULT" {
            // An answer with nothing in it is still an answer: the round trip
            // happened, which is all this measures.
        } catch {
            return nil
        }
        guard connection === self.connection else { return nil }
        let taken = ContinuousClock.now - started
        let milliseconds = Double(taken.components.seconds) * 1000
            + Double(taken.components.attoseconds) / 1e15
        latencySamples.append(milliseconds)
        if latencySamples.count > Self.latencyHistory {
            latencySamples.removeFirst(latencySamples.count - Self.latencyHistory)
        }
        return milliseconds
    }

    /// The host's answer to `ping`: its own clock, which is not needed here.
    private struct PingResult: Decodable, Sendable {
        let time: Double?
    }

    /// Put what this phone already knows on screen, before asking anybody.
    ///
    /// The point of the stored index. Every one of these three used to be the
    /// result of a request made while the screen was opening, so a phone on a
    /// slow link showed an empty list and unnamed sessions until the round trip
    /// came back -- and showed them forever if it never did.
    ///
    /// Reading it is a disk trip, and the machine can change during one: a
    /// slower read of the first computer's list landing after the operator switched
    /// draws that computer's sessions under this one. The machine is recorded before
    /// the read and checked after it, which is the same rule the network reads
    /// follow. The socket is deliberately not part of it: this runs before the
    /// handshake, and a stored list belongs to the machine rather than to the
    /// connection that happens to be opening.
    ///
    /// - Parameter hostId: the machine to read for.
    private func loadIndex(for hostId: String) async {
        // The *machine* being opened, not the current connection: this read runs
        // before the handshake, and `currentTag` is deliberately nil until there
        // is a socket. Asking for the tag here abandoned every stored index on
        // launch -- the list was empty until the network answered, and stayed
        // empty when it did not, which is the one case the cache exists for.
        guard host?.hostId == hostId else {
            log.add(.cache, "index: read for \(hostId) abandoned, that machine is no longer open")
            return
        }
        guard let stored = await indexStore.load(hostId: hostId) else {
            hasStoredIndex = false
            log.add(.cache, "index: nothing stored for this machine yet")
            return
        }
        // After the await: what the phone holds is the first computer's list, and the
        // second computer is the one on screen.
        guard host?.hostId == hostId else {
            log.add(.cache, "index: read for \(hostId) abandoned, another machine was opened under it")
            return
        }
        hasStoredIndex = !stored.sessions.isEmpty
        // The phone knows what the computer last said, even when what it said was
        // "nothing". That is a fact the Live Activity may act on; an array that
        // was never filled is not.
        sessionsAreKnown = true
        log.add(
            .cache,
            "index: read \(stored.sessions.count) sessions, \(stored.titles.count) titles"
                + (stored.workspaces.map { ", \($0.count) workspaces" } ?? ", no workspace list"),
        )
        // Only ever adds. A stored list that is empty must not be able to wipe
        // what a live read has already put on screen.
        //
        // Filtered on the way out of the cache for the same reason the network
        // read is: an index written before the phone could choose, or by another
        // agent on this computer, holds rows this connection cannot open. The
        // report that started this was a phone showing them -- a list that is
        // right while connected and wrong on the next launch is not right.
        let storedSessions = Self.scoped(stored.sessions, to: engineScope)
        if !storedSessions.isEmpty { sessions = storedSessions }
        if !stored.titles.isEmpty { titles.merge(stored.titles) { _, stored in stored } }
        // Not merged: a workspace is not something to accumulate. This is the
        // host's last answer, whole, and unioning a second answer into it is how
        // a deleted workspace survives a refresh -- which is the bug this exists
        // to fix. `nil` stays `nil`: knowing nothing is not the same as knowing
        // there is nothing.
        if let storedWorkspaces = stored.workspaces {
            workspaces = Self.scoped(storedWorkspaces, to: engineScope)
        }
    }

    /// Write down what is on screen, so a later launch starts from it.
    ///
    /// Called after every successful update rather than on a timer: the stored
    /// index is then always the last thing the host actually said, and never a
    /// mixture of that and something this app inferred.
    private func persistIndex() async {
        guard let hostId = host?.hostId else { return }
        log.add(
            .cache,
            "index: wrote \(sessions.count) sessions, \(titles.count) titles"
                + (workspaces.map { ", \($0.count) workspaces" } ?? ", no workspace list"),
        )
        await indexStore.save(
            SessionIndex(
                hostId: hostId,
                sessions: sessions,
                titles: titles,
                workspaces: workspaces,
            ),
        )
    }

    /// Start the first connect once, from a task the view lifecycle cannot cancel.
    ///
    /// Safe to call from every appearance: the second call is a no-op.
    func scheduleStart() {
        guard startTask == nil else { return }
        startTask = Task { [weak self] in
            await self?.start()
        }
    }

    /// What is stored about this phone's pairing, read without a screen.
    ///
    /// `host` is set by ``start()``, which a background launch never runs: a
    /// `BGAppRefreshTask` wake arrives before any view, and the root view's
    /// `.task` is what calls ``scheduleStart()``. A wake that decided from
    /// `host` alone would write "no computer is paired" about a phone that has
    /// one -- true of a model nobody loaded, false of the phone, and the log is
    /// the only evidence a wake leaves behind.
    ///
    /// So the store is asked directly. It is a keychain read of a handful of
    /// items, and the fast path is the foreground one, where `host` already says
    /// the answer.
    ///
    /// - Returns: what the credentials store says. `.unknown` when it cannot be
    ///   read -- the keychain does not answer before the first unlock after a
    ///   restart -- which is a third answer, not "no computer".
    func storedPairing() async -> BackgroundSync.Pairing {
        if host != nil { return .paired }
        do {
            return try await credentials.loadAll().isEmpty ? .unpaired : .paired
        } catch {
            return .unknown
        }
    }

    /// Load any stored pairing and, if there is one, connect.
    ///
    /// A pairing URI passed on the command line takes precedence, which is what
    /// makes the app drivable from `simctl launch` and from a UI test without
    /// typing into fields or tapping through an alert. It is the same payload
    /// the QR carries, so the path exercised is the real one.
    func start() async {
        guard !hasStarted else { return }
        hasStarted = true
        // Launching is opening the app, so the Live Activity's flag starts set.
        // Only the flag: the session list has not been read yet, and "nothing is
        // running" must not be confused with "nothing is known".
        liveActivity.appOpened()
        log.add(
            .app,
            "launch \(Self.versionLine) on \(Self.deviceModel); flags: \(Self.launchFlags.joined(separator: " "))",
        )
        // What the switches were at this launch, which is the one line that
        // answers "I turned that off, why did it still arrive" from a log alone:
        // a push that was suppressed and a push that arrived because the switch
        // was never written down look identical from the notification.
        let suppressed = settings.values.notifications.suppressed
        log.add(
            .settings,
            "loaded: "
                + (suppressed.isEmpty
                    ? "every notification kind on"
                    : "off: \(suppressed.map(\.rawValue).sorted().joined(separator: ", "))")
                + "; live activity \(settings.values.liveActivitiesEnabled ? "on" : "off")",
        )
        if Self.launchResetsCache {
            // Before the first read, not after: everything below loads what is
            // stored, so this is the only place where "start empty" can be true.
            //
            // Both stores, because "start from nothing" is a claim about the
            // whole app: leaving the index behind would show a fixture's session
            // list under a fresh install's pairing.
            await conversations.clear()
            await indexStore.clear()
            log.add(.cache, "starting from nothing: stored conversations and index cleared")
        }
        if !Self.launchPairingURIs.isEmpty {
            // Every URI, in order, not just the first. A phone that manages two
            // computers is a supported arrangement and this is the only way to reach
            // it without walking the pairing screen once per machine -- and it
            // is the arrangement in which anything scoped to one machine can be
            // seen at all. The last one paired is the one left open, which is
            // what makes the order meaningful.
            for raw in Self.launchPairingURIs {
                guard let target = PairingURI.parse(raw) else { continue }
                await pair(with: target, deviceName: "iPhone")
            }
            return
        }
        do {
            hosts = try await credentials.loadAll().sorted { $0.pairedAt < $1.pairedAt }
            // The machine the operator last opened, not the one paired last:
            // with several computers paired, "paired last" is a fact about a past
            // setup step, and opening it leaves the session list, the pending
            // approvals, the Live Activity and the push registration on a computer
            // the operator was not using. `HostSelection` also owns the fallback
            // for a fresh install and a forgotten machine.
            guard let stored = HostSelection.preferred(
                in: hosts,
                lastOpenedId: LastOpenedHostStore.stored(),
            ) else {
                phase = .unpaired
                return
            }
            host = stored
            // Written back so an install from before this rule starts keeping
            // the memory from the machine it is opening now.
            LastOpenedHostStore.store(stored.hostId)
            try await connect(using: stored)
        } catch {
            failConnection(error, authority: host?.authority)
        }
    }

    /// Open a different machine from the list.
    ///
    /// The whole host-scoped half of the app goes with the machine that is being
    /// left: a catalogue, a pending set, a session list and the model each
    /// session was last told to use are all facts about *that* computer, and the
    /// screen draws them for whichever machine is open.
    ///
    /// - Parameter hostId: the machine to open.
    func open(hostId: String) async {
        guard let next = hosts.first(where: { $0.hostId == hostId }) else { return }
        // Leaving the on-device agent is its own act: a running local turn is
        // stopped rather than left executing behind a screen that can no longer
        // show it (the kernel would still call the model, and an approval that
        // arrived now would fail the turn anyway).
        if isLocalAgentMode { await leaveLocalAgent() }
        let leaving = host?.hostId != next.hostId
        disconnectCurrent()
        // Session ids are the host's, and two machines are two hosts: a choice
        // made on one is not a choice made on the other even when the ids agree,
        // which on a fixture they do. Kept across a reconnect to the *same*
        // machine, where it is still this session's last instruction.
        if leaving { modelChoice = [:] }
        host = next
        // The next launch opens this one. Remembered here, when the operator
        // chose it, rather than when a connection happens to succeed: where they
        // chose to be is the question the next launch asks.
        LastOpenedHostStore.store(next.hostId)
        do {
            try await connect(using: next)
        } catch {
            failConnection(error, authority: next.authority ?? next.baseURL)
        }
    }

    /// Switch the one connection to the on-device agent.
    ///
    /// The same connection object and the same protocol as a computer; only the
    /// transport differs (`LocalKernelTransport` in place of a socket), which is
    /// what keeps every screen, notification and poll working unmodified.
    func enterLocalAgent() async {
        guard !isLocalAgentMode || connection == nil else { return }
        disconnectCurrent()
        host = nil
        activeEndpoint = nil
        mode = .local
        modelChoice = [:]
        phase = .connecting
        log.add(.connection, "starting the on-device agent")
        localAgent.refreshKeyPresence()
        do {
            let started = try await localAgent.start()
            await adoptLocal(started)
        } catch {
            let message = LocalAgentController.describe(error)
            log.add(.connection, "the on-device agent did not start: \(message)")
            // A mode with no connection behind it is not a mode: leaving it set
            // would draw the computer list with the local host id and no host.
            localAgent.stop()
            mode = .remote
            phase = .failed(message)
        }
    }

    /// Stop a running local turn, drop the connection, keep the kernel.
    func leaveLocalAgent() async {
        await stopLocalTurns()
        disconnectCurrent()
        localAgent.stop()
        mode = .remote
        activeEndpoint = nil
        welcome = nil
        // "Unpaired" is a fact about what is stored, not about this moment: a
        // phone with a computer that simply is not connected is connecting, and
        // every caller here goes on to open one (or to say there is none).
        phase = hosts.isEmpty ? .unpaired : .connecting
        localAgent.refreshKeyPresence()
    }

    /// Ask the kernel to stop every local session the app believes is running.
    ///
    /// Best effort, and deliberately before the disconnect: once the socket is
    /// gone the kernel's approval broker treats the turn as unanswered and fails
    /// it, which is a worse ending than "stopped" for both the log and the
    /// operator. A turn this misses is closed the same way it would be after a
    /// crash -- by the kernel, on the next boot.
    private func stopLocalTurns() async {
        guard let connection, isLocalAgentMode else { return }
        for row in sessions where row.running {
            let payload = JSONValue.object(["sessionId": .string(row.sessionId)])
            _ = try? await loggedCall(
                "session.cancel",
                payload: payload,
                on: connection,
                as: AcceptanceResult.self,
            )
        }
    }

    /// Give a machine the name the operator chose for it, on this phone only.
    ///
    /// - Parameters:
    ///   - label: the name, or `nil` to fall back to the host's own.
    ///   - hostId: the machine to rename.
    func rename(hostId: String, to label: String?) async {
        guard let index = hosts.firstIndex(where: { $0.hostId == hostId }) else { return }
        let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines)
        let renamed = hosts[index].renamed(to: (trimmed?.isEmpty ?? true) ? nil : trimmed)
        hosts[index] = renamed
        if host?.hostId == hostId { host = renamed }
        try? await credentials.save(renamed)
        pendingNameHostId = nil
    }

    /// Forget one machine, leaving the others paired.
    /// - Parameter hostId: the machine to forget.
    func forget(hostId: String) async {
        try? await credentials.remove(hostId: hostId)
        // The machine is gone, so what this phone remembers of it is gone too.
        // Leaving it would show one computer's sessions under another's name the next
        // time somebody paired a machine that reused the id.
        await indexStore.remove(hostId: hostId)
        hosts.removeAll { $0.hostId == hostId }
        guard host?.hostId == hostId else { return }
        disconnectCurrent()
        if let next = hosts.last {
            // The same rule as opening one from the list: what this phone was
            // told to use was told to the machine that has just been forgotten.
            modelChoice = [:]
            host = next
            LastOpenedHostStore.store(next.hostId)
            try? await connect(using: next)
        } else {
            modelChoice = [:]
            host = nil
            LastOpenedHostStore.store(nil)
            phase = .unpaired
        }
    }

    /// Surface a failed account connection on the banner the app already has.
    func reportAccountFailure(_ error: any Error) {
        let text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        lastError = text.isEmpty ? nil : text
    }

    /// Keep only the chosen agent's sessions.
    ///
    /// The rule itself is in MizarKit (``WorkspaceCatalog/scoped(_:to:)``), next
    /// to the workspace half and to the tests that hold both, because the two
    /// halves of one screen must not be able to disagree about whose work is on
    /// it.
    ///
    /// - Parameters:
    ///   - rows: the host's rows, or the ones stored.
    ///   - engine: the agent, or `nil` for all of them.
    /// - Returns: the rows to draw.
    static func scoped(_ rows: [SessionRow], to engine: AgentEngine?) -> [SessionRow] {
        WorkspaceCatalog.scoped(rows, to: engine?.wireName)
    }

    /// Keep only the chosen agent's workspaces.
    ///
    /// The second half of the report: a phone scoped to DSH listed DSH's five
    /// folders and, under them, Codex's two, drawn as empty headings because the
    /// sessions in them had already been filtered out. The host no longer sends
    /// them, and this is the phone's own answer to the same question -- for an
    /// older host, for a list stored before this rule existed, and for the frame
    /// between a reconnect and the first answer.
    ///
    /// - Parameters:
    ///   - rows: the host's rows, or the ones stored.
    ///   - engine: the agent, or `nil` for all of them.
    /// - Returns: the rows to draw.
    static func scoped(_ rows: [WorkspaceRow], to engine: AgentEngine?) -> [WorkspaceRow] {
        WorkspaceCatalog.scoped(rows, to: engine?.wireName)
    }

    /// Open a computer the account found, with the token the relay brokered.
    ///
    /// The token is the same kind pairing issues, so the rest of the app only
    /// needs a `PairedHost`: the room is the address, and the account's device
    /// id is the local key. A later `host.info` may teach this record the
    /// computer's own name; the key stays this account's handle for it.
    ///
    /// - Parameters:
    ///   - desktop: the computer, as `/account/v1/desktops` listed it.
    ///   - connection: the room and token `/account/v1/connect` handed back.
    ///   - origin: the account relay's origin, without a path.
    func openAccountDesktop(
        _ desktop: AccountDesktop,
        using connection: DesktopConnection,
        at origin: URL,
        engine: AgentEngine? = nil,
    ) async {
        // Set before the socket opens: the first list read must already be
        // filtered, or the phone shows every agent's sessions for one frame.
        engineScope = engine
        let baseURL = origin
            .appendingPathComponent("r")
            .appendingPathComponent(connection.room)
            .absoluteString
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        // appendingPathComponent escapes nothing in an https URL, but trimming
        // the trailing slash keeps it equal to a paired host's baseURL.
        let paired = PairedHost(
            hostId: desktop.deviceId,
            hostName: desktop.name,
            authority: nil,
            deviceId: desktop.deviceId,
            deviceToken: connection.token,
            baseURL: baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL,
            // The relay already minted this token for the agent, so the computer
            // will answer only that agent's rows. Storing the choice is what
            // makes the phone's own filters agree with it on the next launch.
            engine: engine?.rawValue,
        )
        try? await credentials.save(paired)
        if let index = hosts.firstIndex(where: { $0.hostId == paired.hostId }) {
            hosts[index] = paired
        } else {
            hosts.append(paired)
        }
        await open(hostId: paired.hostId)
    }

    /// Tear the live connection down without touching what is stored.
    private func disconnectCurrent() {
        if connection != nil { log.add(.connection, "closing the connection") }
        // Every path that drops a connection drops the mode with it: a pairing,
        // a forget and a switch all end whatever this phone was connected to,
        // and the on-device agent keeps its kernel but not its lambda. Leaving
        // `mode` behind here is how a computer's session list would be drawn
        // under the local agent's host id.
        if isLocalAgentMode {
            localAgent.stop()
            mode = .remote
        }
        interactionPoll?.cancel()
        eventListener?.cancel()
        // Captured, not read inside the task. `Task { await connection?.disconnect() }`
        // reads `connection` when the task *runs*, which can be after the next
        // machine's socket has been assigned -- so the task closed the new
        // connection instead of the old one, and a second pairing failed to
        // connect with "Socket is not connected" before it had said hello.
        let closing = connection
        connection = nil
        engineScope = nil
        if let closing { Task { await closing.disconnect() } }
        welcome = nil
        // The cross belonged to the link that was just closed. A redial, or a
        // different computer, is a new picture.
        linkFailure = nil
        sessions = []
        sessionsAreKnown = false
        selectedSessionId = nil
        statsError = nil
        conversationError = nil
        // Per-machine facts, cleared with the machine. `workspaces` is that
        // computer's own list: leaving it in place means the next machine's sessions
        // are drawn under this one's workspace names -- and a deleted workspace
        // belonging to a computer this phone is no longer paired with comes back.
        titles = [:]
        workspaces = nil
        hasStoredIndex = false
        // The catalogues, the pending set and the host events are that computer's too,
        // and they are kept rather than re-read: leaving them is how the second
        // machine's picker offered the first machine's models. They are also
        // tagged, so they could not be *read* after a switch -- dropping them
        // here is what keeps "what this phone holds" honest as well.
        modelCatalogState.clear()
        permissionCatalogState.clear()
        pendingState.clear()
        recentHostEventState.clear()
        // A held prompt belongs to a session on the machine being left. It
        // cannot be sent anywhere else, and carrying it over would put a bar
        // over a conversation on the next computer with words typed about this
        // one. The log says it was dropped rather than sent, so a prompt that
        // never arrives has an answer in the export.
        if !pendingPrompts.isEmpty {
            log.add(.sync, "\(pendingPrompts.count) held prompt(s) dropped with the computer they were for")
        }
        for delivery in heldDeliveries.values { delivery.task.cancel() }
        heldDeliveries = [:]
        deliveringHeldPrompts = []
        pendingPrompts = [:]
        deliveredPrompts = [:]
        // A choice about the next session on *that* machine, and the next machine
        // may not offer the model at all.
        newSessionModel = nil
        // A preset accepted here is a fact about a session on this computer.
        appliedPermissions = [:]
        phase = .launching
    }

    /// Every `mizar://pair` URI from the launch arguments, in the order passed.
    ///
    /// Repeated rather than single, because a phone paired with two computers is the
    /// arrangement the host list exists for and the one an automated run has to
    /// be able to reach: walking the pairing screen twice is a test of the
    /// pairing screen, not of what happens after it. The last one passed is the
    /// one the app is left on.
    private static var launchPairingURIs: [String] {
        launchArguments("-mizarPairURI")
    }

    /// A session to open on launch, from the launch arguments.
    ///
    /// `first` means the newest session. Paired with `-mizarPairURI` this is the
    /// whole automation entry point: it makes any screen reachable from
    /// `simctl launch` without a tap, which is the difference between a UI that
    /// is built and a UI that has been seen working.
    private static var launchSelectedSession: String? {
        launchArgument("-mizarSelectSession")
    }

    /// Whether to throw the stored conversations away before anything loads.
    ///
    /// The cache is meant to be long-lived -- being able to see yesterday's
    /// conversation without a network is the point of it -- so it survives
    /// relaunches and, in the simulator, it survives reinstalls of the same
    /// bundle. That makes a UI test lie: measure a screen against a fixture and
    /// the screen may be showing a fixture from a week ago, merged with the new
    /// one, which is exactly what "the turn has 5 steps and is still running"
    /// turned out to be.
    ///
    /// A test that asserts on a fixture has to say it wants the fixture and
    /// nothing else.
    private static var launchResetsCache: Bool {
        ProcessInfo.processInfo.arguments.contains("-mizarFreshStart")
    }

    /// Whether to report a LAN link no matter what the live route is.
    ///
    /// Debug-only, and only for UI tests: the fixture is reached over loopback,
    /// which the real rule excludes, so without this flag the LAN-unlocked UI
    /// could not be driven by a test. The flag is read where the rule lives
    /// (``isLocalCommunication``) so no other code branches on it.
    private static var launchForcesLocalNetwork: Bool {
        ProcessInfo.processInfo.arguments.contains("-mizarLocalNetwork")
    }

    /// Read a `-flag value` pair from the launch arguments.
    /// - Parameter flag: the flag to look for.
    /// - Returns: the value, or `nil` when the flag is absent.
    private static func launchArgument(_ flag: String) -> String? {
        launchArguments(flag).first
    }

    /// Read every `-flag value` pair for one flag, in the order passed.
    ///
    /// - Parameter flag: the flag to look for.
    /// - Returns: the values, empty when the flag is absent.
    private static func launchArguments(_ flag: String) -> [String] {
        let arguments = ProcessInfo.processInfo.arguments
        var values: [String] = []
        for (index, argument) in arguments.enumerated() where argument == flag {
            let value = arguments.index(after: index)
            if value < arguments.endIndex { values.append(arguments[value]) }
        }
        return values
    }

    /// Tell the running poll whether the app is on screen.
    ///
    /// Called from the root view's `scenePhase` change. Leaving the screen stops
    /// the poll rather than letting it sleep: iOS suspends the process anyway,
    /// and a task that is merely asleep when the process is frozen resumes with
    /// a stale tick. Coming back starts it again, from what the last read said;
    /// if that is out of date, the tick ten seconds later is the read that
    /// corrects it.
    ///
    /// - Parameter active: whether the app is `.active`.
    func setAppActive(_ active: Bool) {
        guard active != appIsActive else { return }
        appIsActive = active
        updateRunningPoll()
        updateLanWatch()
        // A prompt held while the app was in the background is due the moment
        // the operator is back: the turn may have ended ten minutes ago and the
        // list the app came back with is the one that says so.
        if active { deliverHeldPromptsIfDue() }
    }

    /// Tell the running poll what the open conversation is drawing.
    ///
    /// Called by the conversation screen whenever it puts turns on screen --
    /// from the cache before the network is asked, and from the page afterwards
    /// -- because the screen is the only place that knows what "the open
    /// conversation" is. Only the session on screen counts: a running turn in a
    /// conversation nobody is looking at is not the answer the list failed to
    /// give.
    ///
    /// The value is replaced, not latched on. A page whose running turn has
    /// ended is the evidence that the turn stopped, and with the list also
    /// saying nothing is running that is what lets the poll stand down. A failed
    /// or cancelled read never reaches here, which is deliberate: it is not
    /// evidence about the turn.
    ///
    /// - Parameters:
    ///   - turns: the turns the conversation screen is drawing.
    ///   - sessionId: the session they belong to.
    func noteConversationTurns(_ turns: [ConversationTurn], for sessionId: String) {
        guard sessionId == selectedSessionId else { return }
        let running = turns.contains(where: \.isRunning)
        guard running != openConversationTurnIsRunning else { return }
        openConversationTurnIsRunning = running
        updateRunningPoll()
    }

    /// Mark a session as running because the host accepted a prompt for it.
    ///
    /// The session list is not re-read after a send -- the conversation is -- so
    /// the list can keep saying the session is stopped for as long as nothing
    /// else asks. An accepted `session.prompt` (or an answer that continues the
    /// turn) is direct evidence that a turn is executing; the row is marked
    /// locally so the poll's existing start condition sees it at once, and the
    /// poll's own list read replaces it with the host's answer at the first
    /// tick. That is the cheapest correct thing: no extra request, no race with
    /// the host recording the turn, and nothing that can stay wrong beyond one
    /// interval.
    ///
    /// - Parameter sessionId: the session the prompt was accepted for.
    private func notePromptAccepted(for sessionId: String) {
        let marked = RunningPoll.markingSessionRunning(in: sessions, sessionId: sessionId)
        guard marked != sessions else { return }
        sessions = marked
    }

    /// Start or stop the running poll from what the last list and page said.
    ///
    /// The one place the decision is made, called from `sessions`'s observer --
    /// so every assignment of the list, from every read, is enough -- and from
    /// the app's active flag, a prompt being accepted, and the conversation
    /// screen reporting its turns. The state machine answers `.none` when the
    /// task is already in the right state, which is what keeps a manual refresh
    /// from restarting the tick clock.
    private func updateRunningPoll() {
        switch runningPollState.observe(
            anySessionRunning: RunningPoll.anySessionRunning(in: sessions),
            conversationTurnIsRunning: openConversationTurnIsRunning,
            appIsActive: appIsActive,
        ) {
        case .start:
            startRunningPoll()
        case .stop:
            stopRunningPoll()
        case .none:
            break
        }
    }

    /// Start the one background task that keeps asking while something runs.
    ///
    /// The shape is the pending-interactions poll's: one task property, a sleep
    /// first, and a loop that ends when the task is cancelled. The sleep is first
    /// on purpose -- the read that found the running session has just happened,
    /// so asking again immediately would be traffic for an answer ten seconds
    /// old at most.
    private func startRunningPoll() {
        // The state machine and this guard say the same thing; the guard is what
        // makes it true even if a cancelled task has not been deallocated yet.
        guard runningPoll == nil else { return }
        log.add(.sync, "running poll: started, a session is running")
        runningPoll = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    // Read each tick rather than captured once: the route can
                    // change under a poll (a manual refresh that finds the LAN),
                    // and the next sleep is the first place that can act on it.
                    try await Task.sleep(for: self?.runningPollInterval ?? RunningPoll.interval)
                } catch {
                    // Cancellation is the stop path; there is nothing to report.
                    return
                }
                guard !Task.isCancelled, let self else { return }
                await self.runningPollTick()
            }
        }
    }

    /// Stop the running poll, if one is up.
    private func stopRunningPoll() {
        guard let runningPoll else { return }
        runningPoll.cancel()
        self.runningPoll = nil
        // A stopped poll starts over: the next one begins from a clean count
        // rather than inheriting failures from a turn that has since ended.
        runningPollRecovery.reset()
        log.add(
            .sync,
            appIsActive
                ? "running poll: stopped, nothing is running"
                : "running poll: stopped, the app is not on screen",
        )
    }

    /// One read of the world the poll exists for: the session list.
    ///
    /// Deliberately not ``refreshSessions(reconnectingIfNeeded:)``. That is the
    /// foreground refresh: it re-reads the workspace registry, writes the stored
    /// index, and its call reconnects a socket that failed. On a ten-second
    /// clock, each of those turns a computer that is asleep into work nobody asked
    /// for -- a handshake every tick, and a disk write every tick -- and the
    /// whole reason this poll is allowed to exist is that it costs almost
    /// nothing. So a tick is exactly one `session.list` on the connection the
    /// app already has, with no reconnect and no retry of its own. A failure is
    /// left in the request log, the screen keeps what it had, and the next tick
    /// is the retry.
    ///
    /// What it must do is the half of the answer the screen and the island read:
    /// the list, and the Live Activity decision made from it -- the same
    /// controller call the foreground refresh makes, because a finished turn
    /// should end the activity through one path, not two.
    ///
    /// The tick is counted after the read even when the read found nothing
    /// running: that is the read the open conversation needs to see in order to
    /// draw the finished row, and by then this task is already being cancelled
    /// by the observer above -- the counter is the last thing it does.
    private func runningPollTick() async {
        guard appIsActive, runningPollState.isPolling else { return }
        // A tick that cannot read is not retried on the socket it just failed
        // on. The poll is the only thing still asking on a screen nobody has
        // touched, so a dead socket here is the difference between "the turn
        // finished" and a list that says it is still running until somebody
        // pulls to refresh. The policy is deliberately cheap: two failures earn
        // one attempt, and attempts are half a minute apart.
        if runningPollRecovery.reconnectIsDue(
            connectionMissing: connection == nil,
            now: ContinuousClock.now,
        ) {
            runningPollRecovery.noteAttempt(at: ContinuousClock.now)
            if await reconnect() {
                runningPollRecovery.recordSuccess()
            }
        }
        await refreshRunningSessionList()
        lastPollTickAt = Date()
        runningPollTicks &+= 1
    }

    /// The poll's one request: what is running, as the host answers now.
    ///
    /// Silent on failure by design. A failed tick is not a new problem for the
    /// operator -- the banner over the list already carries the last failure
    /// they can act on -- and a poll that flashed an error every ten seconds
    /// while the computer slept would be the app complaining about its own timer.
    private func refreshRunningSessionList() async {
        guard let tag = currentTag else { return }
        guard let connection else {
            // No socket at all: there is nothing to ask, and the operator's
            // screen is the thing going stale. Counted so the next tick may
            // rebuild it rather than asking nothing for ever.
            runningPollRecovery.recordFailure()
            return
        }
        do {
            let result = try await loggedCall("session.list", on: connection, as: SessionListResult.self)
            guard tag == currentTag else {
                log.add(.cache, "running poll: list for \(tag.hostId) dropped, the machine changed under it")
                return
            }
            // The socket answered: whatever failed before is not failing now.
            runningPollRecovery.recordSuccess()
            sessions = Self.scoped(result.items, to: engineScope)
            sessionsAreKnown = true
            lastError = nil
            // Read after the list, with the clock at the same instant: which
            // sessions are running is half of what the activity shows, and this
            // is the read that knows. It is the controller's existing entry
            // point, not a second decision path.
            await refreshLiveActivity()
        } catch {
            // Cancellation is this poll being stopped, not a failure: the app
            // was backgrounded, or another read found nothing running. Leave the
            // screen alone and let the loop end.
            if Task.isCancelled { return }
            // Only failures a fresh socket could fix count towards a reconnect.
            // An answer the host chose to send would be the same answer over a
            // new socket, and rebuilding the connection for it is real seconds
            // on a phone spent on nothing.
            //
            // No banner either way: the failure is already in the request log by
            // `loggedCall`, which is where "did the poll keep asking" is asked.
            if Self.isAboutTheConnection(error) {
                runningPollRecovery.recordFailure()
            }
        }
    }

    /// React to what the host pushes, and fall back to asking occasionally.
    private func startInteractionPoll() {
        interactionPoll?.cancel()
        interactionPoll = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshInteractions()
                try? await Task.sleep(for: Self.interactionPollSeconds)
            }
        }

        eventListener?.cancel()
        eventListener = Task { [weak self] in
            guard let self else { return }
            // The connection the stream belongs to, captured before the first
            // suspension: a reconnect during this task replaces the model's
            // connection, and the end of the old stream must not clear the new
            // socket.
            guard let opened = self.connection else { return }
            let stream = await opened.events()
            for await frame in stream {
                guard case .event(let name, let data) = frame else { continue }
                self.noteHostEvent(name)
                if name == "relay.changed" {
                    await self.applyRelayChanged(data)
                    continue
                }
                // Any other event name is for a future build; ignoring it is not
                // the same as failing on it.
                guard Self.interactionEvents.contains(name) else { continue }
                await self.refreshInteractions()
            }
            // A stream ends when the socket does. Clearing the reference here is
            // what lets the next read take the reconnect path instead of asking
            // a dead transport for an answer.
            guard !Task.isCancelled else { return }
            await self.noteSocketClosed(opened)
        }
    }

    /// Note that the socket behind the current connection has gone.
    ///
    /// The event stream is the one signal a dead socket gives without a request
    /// being made: its loop finishes when the read loop tears the transport down.
    /// Before this, the model kept the dead object, and every later read was
    /// answered by it with `SOCKET_CLOSED` -- an error that asked for no
    /// reconnect, so the phone sat saying "the socket is not open" until the app
    /// was relaunched. Clearing the reference makes the next read open a new
    /// socket, which is the recovery every refresh path already has.
    ///
    /// - Parameter closed: the connection whose event stream ended.
    private func noteSocketClosed(_ closed: MizarConnection) async {
        // A reconnect may already have replaced it; only the socket that is
        // still the model's is this method's to forget.
        guard connection === closed else { return }
        connection = nil
        log.add(.connection, "the socket closed; the next read reconnects")

        // The one close the operator must see rather than infer: the relay
        // refuses more bytes once the day's allowance is gone, and closes this
        // socket with that sentence as the reason.
        if let reason = await closed.closeReason(), reason.contains("traffic allowance spent") {
            log.add(.connection, "the relay closed the socket: the daily traffic allowance is spent")
            trafficNotice = true
        }

        // A socket that dies on the operator's own network is the one close
        // that cannot be left to the next read. Waiting for one would ask the
        // lost address again and again -- the reported bug: the phone sat in a
        // reconnect loop on the LAN it had left while the relay in the same
        // pairing was never tried. The relay goes first here because the one
        // fact this close carries is that the local network is gone; the direct
        // address is still in the plan behind it, for a Wi-Fi blip.
        guard activeEndpoint?.isLocalNetwork == true, appIsActive, !reconnecting else { return }
        if settings.values.localNetworkFirst {
            // The operator asked to look for the computer on their own network
            // before giving up on it. On a phone that changed Wi-Fi networks
            // the stored address is often dead but the *new* one answers, and
            // this is the one automatic reconnect that can still find it.
            log.add(.connection, "the local link closed; asking the local network before the relay")
            Task { [weak self] in
                guard let self else { return }
                let switched = await self.scanForLocalNetwork()
                if !switched, !(await self.reconnect(preferringRelay: true)) { return }
                await self.refreshSessions(reconnectingIfNeeded: false)
                await self.refreshInteractions()
            }
            return
        }
        log.add(.connection, "the local link closed; failing over to the relay")
        Task { [weak self] in
            guard let self else { return }
            guard await self.reconnect(preferringRelay: true) else { return }
            await self.refreshSessions(reconnectingIfNeeded: false)
            await self.refreshInteractions()
        }
    }

    /// Write down that the host pushed something.
    ///
    /// Every event, not only the four that move the pending set: "the host said
    /// nothing at all" and "the host said something this build ignored" look
    /// identical from the screen, and they have completely different answers.
    ///
    /// - Parameter name: the event name.
    private func noteHostEvent(_ name: String) {
        // Scoped to the machine that pushed it. The export's "did the host tell
        // us anything" question is about *this* host, and a list that survived a
        // switch answers it with the previous computer's events.
        guard let tag = currentTag else { return }
        var events = recentHostEventState.value(for: tag) ?? []
        events.insert(HostSummary.Event(at: Date(), name: name), at: 0)
        if events.count > Self.recentHostEventLimit {
            events.removeLast(events.count - Self.recentHostEventLimit)
        }
        recentHostEventState.publish(events, for: tag)
        log.add(.host, "event \(name)")
    }

    /// How many host events are kept for the log export.
    private static let recentHostEventLimit = 50

    /// Read the pending approvals and questions.
    ///
    /// A read that fails leaves the last answer alone, and that is not tidiness.
    /// `pending = try? …` wrote `nil` on any failure, and two readers start at
    /// once on this — the poll below and the session screen's own refresh — so a
    /// slower *failure* could land after the other one's success and wipe a card
    /// that was already on screen. Nothing then re-read it for 45 seconds, which
    /// is how an approval or a question went missing for the whole of a UI
    /// test's twenty-second wait while every other figure on the screen was
    /// loaded.
    ///
    /// With nothing on screen there is nothing to lose, so that case gets one
    /// more try rather than a 45-second wait: a card the agent is blocked on is
    /// the most urgent thing the app draws.
    func refreshInteractions() async {
        guard let connection, let tag = currentTag else { return }
        if let read = try? await loggedCall("interactions.pending", on: connection, as: PendingInteractions.self) {
            // Only if this is still the machine the read was started for. The
            // poll outlives a switch -- it is cancelled on one, but a read
            // already in flight is not -- and a card from the previous computer drawn
            // over this one is an approval for a session that is not here.
            guard tag == currentTag else { return }
            pendingState.publish(read, for: tag)
            return
        }
        guard pending == nil else { return }
        try? await Task.sleep(for: .milliseconds(600))
        if let retried = try? await loggedCall("interactions.pending", on: connection, as: PendingInteractions.self) {
            guard tag == currentTag else { return }
            pendingState.publish(retried, for: tag)
        }
    }

    /// Answer an approval.
    ///
    /// - Parameters:
    ///   - approval: the request being answered.
    ///   - outcome: what to do with it.
    func answerApproval(_ approval: PendingApproval, outcome: ApprovalOutcome) async {
        guard let connection else { return }
        let payload = JSONValue.object([
            "requestId": .string(approval.requestId),
            "outcome": .string(outcome.rawValue),
        ])
        let accepted = (try? await loggedCall(
            "approval.answer",
            payload: payload,
            on: connection,
            as: AcceptanceResult.self,
        ))?.accepted ?? false
        // An approval that lets the agent continue is a prompt by another name:
        // the host is about to run a turn for this session, and the app does not
        // re-read the list after answering. Direct evidence, like a send.
        if accepted, let sessionId = approval.sessionId {
            notePromptAccepted(for: sessionId)
        }
        // Re-read rather than removing locally: the host is the authority on
        // what is still outstanding, and a racing device may have answered it.
        await refreshInteractions()
    }

    /// Answer a whole question batch.
    /// - Parameters:
    ///   - question: the batch being answered.
    ///   - answers: one answer per question, in the batch's order.
    func answerQuestion(_ question: PendingQuestion, answers: [QuestionAnswer]) async {
        guard let connection else { return }
        let payload = JSONValue.object(["callId": .string(question.callId)])
        let batch = QuestionAnswerBatch(answers: answers)
        guard let encoded = try? JSONEncoder().encode(batch),
              let value = try? JSONDecoder().decode(JSONValue.self, from: encoded)
        else { return }
        var merged = payload
        if case .object(var fields) = merged, case .object(let batchFields) = value {
            for (key, fieldValue) in batchFields { fields[key] = fieldValue }
            merged = .object(fields)
        }
        let accepted = (try? await loggedCall(
            "question.answer",
            payload: merged,
            on: connection,
            as: AcceptanceResult.self,
        ))?.accepted ?? false
        // An answer that continues a turn is a prompt by another name. The
        // list is not re-read after this call, so the accepted answer is the
        // evidence the running poll starts from.
        if accepted, let sessionId = question.sessionId {
            notePromptAccepted(for: sessionId)
        }
        await refreshInteractions()
    }

    /// Load the model and permission catalogs, once.
    ///
    /// Once per *machine*: both are read for the host that is connected now and
    /// recorded as that machine's answer, so a switch reads the new machine's
    /// catalogue rather than drawing the old one's models.
    func loadCatalogs() async {
        guard let connection, let tag = currentTag else { return }
        if modelCatalog == nil {
            if let read = try? await loggedCall("model.catalog", on: connection, as: ModelCatalog.self) {
                guard tag == currentTag else { return }
                modelCatalogState.publish(read, for: tag)
            }
        }
        if permissionCatalog == nil {
            if let read = try? await loggedCall("permissions.catalog", on: connection, as: PermissionCatalog.self) {
                guard tag == currentTag else { return }
                permissionCatalogState.publish(read, for: tag)
            }
        }
    }

    /// Forget the cached catalogues and read them again.
    ///
    /// A provider added in Settings is a new model in the picker, and
    /// ``loadCatalogs`` only asks a machine that has not answered yet. This is
    /// the one caller that has a reason to ask twice.
    func reloadCatalogs() async {
        guard connection != nil else { return }
        modelCatalogState.clear()
        permissionCatalogState.clear()
        await loadCatalogs()
    }

    /// Send a prompt to a session.
    ///
    /// - Parameters:
    ///   - text: what to say.
    ///   - sessionId: the session to say it to.
    ///   - mode: how to hand it over when a turn is running: queued for the end
    ///     of it, or fed to it as guidance. See ``PromptMode``.
    /// - Returns: whether the host accepted it.
    @discardableResult
    func sendPrompt(_ text: String, to sessionId: String, mode: PromptMode = .queue) async -> Bool {
        guard let connection, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        // A fresh key per submission: the host uses it to make a retry of the
        // same prompt idempotent, and reusing one would make a second, genuinely
        // different prompt look like a duplicate.
        let requestId = UUID().uuidString
        var fields: [String: JSONValue] = [
            "sessionId": .string(sessionId),
            "text": .string(text),
            "requestId": .string(requestId),
        ]
        // Only `steer` travels. `queue` is the host's default and an old plugin
        // has never heard of the field; spelling out the default on every send
        // would put every ordinary prompt behind a newer plugin. See
        // ``PromptMode/isExplicitOnTheWire``.
        if mode.isExplicitOnTheWire { fields["mode"] = .string(mode.rawValue) }
        do {
            let result = try await loggedCall(
                "session.prompt",
                payload: .object(fields),
                on: connection,
                as: PromptResult.self,
            )
            // Direct evidence, before any list read: the host has accepted a
            // prompt, so a turn is executing for this session whether or not the
            // list the app holds says so. See ``notePromptAccepted(for:)``.
            if result.accepted { notePromptAccepted(for: sessionId) }
            return result.accepted
        } catch {
            phase = .failed(Self.describe(error, authority: host?.authority))
            return false
        }
    }

    /// Send a prompt that carries attachments.
    ///
    /// The attachments have already been uploaded; what travels here is their
    /// host-issued ids. `text` may be empty — the host accepts a prompt that is
    /// only attachments — but a device talking to an old host plugin is refused
    /// (see ``uploadAttachment``), and the caller shows that as an update
    /// message rather than a send failure.
    ///
    /// - Parameters:
    ///   - text: what to say, possibly empty.
    ///   - attachmentIds: the ids from ``uploadAttachment``; at most 8, of which
    ///     at most 4 are images, as the host enforces.
    ///   - sessionId: the session to send to.
    ///   - mode: how to hand it over when a turn is running. See ``PromptMode``.
    /// - Returns: whether the host accepted it.
    @discardableResult
    func sendPrompt(
        _ text: String,
        attachmentIds: [String],
        to sessionId: String,
        mode: PromptMode = .queue,
    ) async -> Bool {
        guard !attachmentIds.isEmpty else {
            return await sendPrompt(text, to: sessionId, mode: mode)
        }
        guard let connection else { return false }
        guard attachmentIds.count <= 8 else {
            lastError = String(localized: "At most 8 attachments can be sent at once.")
            return false
        }
        let requestId = UUID().uuidString
        var fields: [String: JSONValue] = [
            "sessionId": .string(sessionId),
            "requestId": .string(requestId),
            "attachmentIds": .array(attachmentIds.map { .string($0) }),
        ]
        // Omitted rather than empty: the host documents `text` as optional when
        // attachments exist, and an empty string is a different request from no
        // text at all to a host that trims.
        if !text.isEmpty { fields["text"] = .string(text) }
        if mode.isExplicitOnTheWire { fields["mode"] = .string(mode.rawValue) }
        do {
            let result = try await loggedCall(
                "session.prompt",
                payload: .object(fields),
                on: connection,
                as: PromptResult.self,
            )
            if result.accepted { notePromptAccepted(for: sessionId) }
            return result.accepted
        } catch {
            lastError = Self.describe(error)
            return false
        }
    }

    // MARK: - Prompts held for the end of a turn

    /// The prompt this session is holding, if it is holding one.
    /// - Parameter sessionId: the session to ask about.
    /// - Returns: what would be sent when its turn ends.
    func pendingPrompt(for sessionId: String) -> PendingPrompt? {
        pendingPrompts[sessionId]
    }

    /// The delegated children of one session, as the host lists them.
    ///
    /// The drawer's Subagents page and the count on its tab must be the same
    /// census, or the tab can say three while the page lists two. Both read
    /// this, and neither invents a number while the session list is unknown:
    /// an empty list is "not read yet" as much as it is "none", which is the
    /// same answer the turns segment gives for a conversation with no turns.
    ///
    /// - Parameter sessionId: the parent conversation, or `nil` when none is open.
    /// - Returns: the child rows, in the host's own order.
    func subagents(of sessionId: String?) -> [SessionRow] {
        guard let sessionId else { return [] }
        return sessions.filter { $0.isSubagent(of: sessionId) }
    }

    /// Keep a prompt back until the turn the session is running ends.
    ///
    /// Called by the composer for a text-only send while a turn is running and
    /// guided send is off. Nothing goes on the socket: the prompt is the phone's
    /// until ``deliverHeldPromptsIfDue()`` or the operator decides otherwise, and
    /// that is the whole difference from the host's queue.
    ///
    /// A second send while one is held is added to the same prompt rather than
    /// replacing it or stacking a second bar: one bar means one hand-over, and
    /// dropping the first would lose words the operator already committed to.
    ///
    /// - Parameters:
    ///   - text: what to say.
    ///   - sessionId: the session that is running.
    /// - Returns: whether it was held. An empty prompt is not.
    @discardableResult
    func holdPrompt(_ text: String, for sessionId: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if var held = pendingPrompts[sessionId] {
            held.append(trimmed)
            pendingPrompts[sessionId] = held
            log.add(.sync, "held another prompt for \(sessionId) until its turn ends")
        } else {
            pendingPrompts[sessionId] = PendingPrompt(sessionId: sessionId, text: trimmed)
            log.add(.sync, "held a prompt for \(sessionId) until its turn ends")
        }
        // The turn may already be over as far as the app knows -- a send that
        // raced the host's own ending -- in which case this hands it over now.
        deliverHeldPromptsIfDue()
        return true
    }

    /// Take the held prompt back, for the field.
    /// - Parameter sessionId: the session to take it from.
    /// - Returns: the prompt, or `nil` when there was none.
    @discardableResult
    func takePendingPrompt(for sessionId: String) -> PendingPrompt? {
        guard let held = pendingPrompts.removeValue(forKey: sessionId) else { return nil }
        cancelHeldDelivery(for: sessionId)
        log.add(.sync, "held prompt for \(sessionId) taken back to the field")
        return held
    }

    /// Throw the held prompt away.
    ///
    /// - Parameter sessionId: the session to empty.
    func discardPendingPrompt(for sessionId: String) {
        guard pendingPrompts.removeValue(forKey: sessionId) != nil else { return }
        cancelHeldDelivery(for: sessionId)
        log.add(.sync, "held prompt for \(sessionId) discarded")
    }

    /// Hand the held prompt over now.
    ///
    /// The bar's send button lands here. The prompt leaves the bar before the
    /// request is on the wire, so the bar's exit is answered by the tap rather
    /// than by a round trip; a refusal puts it back, so nothing is lost, and
    /// stops the automatic hand-over from trying on its own -- an operator who
    /// just watched a send fail is the one who gets to decide about a retry.
    ///
    /// - Parameters:
    ///   - sessionId: the session the prompt is held for.
    ///   - mode: `.steer` to feed the running turn as guidance, `.queue` to let
    ///     the host start it.
    /// - Returns: whether the host accepted it.
    @discardableResult
    func sendPendingPrompt(for sessionId: String, as mode: PromptMode) async -> Bool {
        guard !deliveringHeldPrompts.contains(sessionId) else { return false }
        // A retry that is only sleeping is superseded by this tap: the text is
        // the same text, and two hand-overs would be two messages.
        cancelHeldDelivery(for: sessionId)
        let accepted = await deliverHeldPrompt(sessionId: sessionId, as: mode)
        if !accepted { stallHeldDelivery(for: sessionId) }
        return accepted
    }

    /// Note that the conversation screen has drawn a delivered prompt.
    ///
    /// One screen consumes one delivery. Leaving it in place would let a screen
    /// that appears later draw the same message a second time, which is a
    /// duplicate bubble over a conversation that already has the real one.
    ///
    /// - Parameter delivered: the delivery the screen handled.
    func acknowledgeDeliveredPrompt(_ delivered: DeliveredPrompt) {
        guard deliveredPrompts[delivered.sessionId]?.id == delivered.id else { return }
        deliveredPrompts.removeValue(forKey: delivered.sessionId)
    }

    /// Hand over every held prompt whose turn has ended.
    ///
    /// Called from the session list's observer -- the one read that can say a
    /// turn ended while the operator is in another conversation -- and when the
    /// app comes back on screen. The list is the source: a prompt is held only
    /// while its row says running, so a row that stopped is the evidence, and
    /// the conversation page is not consulted (it exists only while a session is
    /// open).
    private func deliverHeldPromptsIfDue() {
        guard !pendingPrompts.isEmpty, phase == .ready, connection != nil else { return }
        for (sessionId, held) in pendingPrompts {
            guard !held.automaticDeliveryStalled else { continue }
            guard heldDeliveries[sessionId] == nil,
                  !deliveringHeldPrompts.contains(sessionId) else { continue }
            guard let row = sessions.first(where: { $0.sessionId == sessionId }), !row.running else { continue }
            startHeldDelivery(for: sessionId)
        }
    }

    /// Start the automatic hand-over for one session.
    /// - Parameter sessionId: the session whose turn has ended.
    private func startHeldDelivery(for sessionId: String) {
        let token = UUID()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runHeldDelivery(for: sessionId)
            // Only the delivery that still owns the entry may clear it: a
            // cancelled retry waking up late must not remove its replacement,
            // which would then be doubled by the next read.
            guard self.heldDeliveries[sessionId]?.token == token else { return }
            self.heldDeliveries.removeValue(forKey: sessionId)
        }
        heldDeliveries[sessionId] = HeldDelivery(token: token, task: task)
    }

    /// Try to hand a held prompt over, with a couple of retries.
    /// - Parameter sessionId: the session whose turn has ended.
    private func runHeldDelivery(for sessionId: String) async {
        for attempt in 0..<Self.heldDeliveryAttempts {
            guard !Task.isCancelled else { return }
            guard pendingPrompts[sessionId] != nil else { return }
            // The turn may have started again -- another phone, the computer,
            // or a prompt that went out over the socket just now -- in which
            // case the held one is for the end of *that* turn.
            guard let row = sessions.first(where: { $0.sessionId == sessionId }), !row.running else { return }
            if await deliverHeldPrompt(sessionId: sessionId, as: .queue) { return }
            guard attempt + 1 < Self.heldDeliveryAttempts else { break }
            do {
                try await Task.sleep(for: .seconds(attempt == 0 ? 2 : 4))
            } catch {
                return
            }
        }
        // Out of attempts. The bar keeps the text and its send key; nothing here
        // asks the host again until the operator does.
        stallHeldDelivery(for: sessionId)
        log.add(.sync, "held prompt for \(sessionId) could not be sent automatically; it stays in the bar")
    }

    /// Stop the automatic hand-over for a session without emptying the bar.
    ///
    /// - Parameter sessionId: the session whose held prompt stays put.
    private func stallHeldDelivery(for sessionId: String) {
        guard var held = pendingPrompts[sessionId] else { return }
        held.stallAutomaticDelivery()
        pendingPrompts[sessionId] = held
    }

    /// The one place a held prompt leaves the phone.
    ///
    /// - Parameters:
    ///   - sessionId: the session it belongs to.
    ///   - mode: how the host should take it. See ``PromptMode``.
    /// - Returns: whether the host accepted it.
    private func deliverHeldPrompt(sessionId: String, as mode: PromptMode) async -> Bool {
        guard !deliveringHeldPrompts.contains(sessionId) else { return false }
        guard let held = pendingPrompts.removeValue(forKey: sessionId) else { return false }
        deliveringHeldPrompts.insert(sessionId)
        defer { deliveringHeldPrompts.remove(sessionId) }
        // Which computer this prompt is for. The request is a suspension, and a
        // host switch clears `pendingPrompts` while it is in flight -- without
        // this, a failure would put the old computer's held prompt back under the
        // new one, and a success would draw it there.
        let hostId = host?.hostId
        let accepted = await sendPrompt(held.text, to: sessionId, mode: mode)
        guard host?.hostId == hostId else {
            log.add(.sync, "held prompt for \(sessionId) finished after its computer was left; dropped")
            return accepted
        }
        guard accepted else {
            restore(held, for: sessionId)
            log.add(.sync, "held prompt for \(sessionId) was refused; it stays in the bar")
            return false
        }
        deliveredPrompts[sessionId] = DeliveredPrompt(sessionId: sessionId, text: held.text)
        log.add(.sync, "held prompt for \(sessionId) sent (\(mode.rawValue))")
        return true
    }

    /// Put a refused prompt back in the bar.
    ///
    /// Anything typed while the request was in flight was held after it, and
    /// keeps its order behind it.
    ///
    /// - Parameters:
    ///   - held: the prompt the host refused.
    ///   - sessionId: the session it belongs to.
    private func restore(_ held: PendingPrompt, for sessionId: String) {
        if var existing = pendingPrompts[sessionId] {
            existing.prepend(held.text)
            pendingPrompts[sessionId] = existing
        } else {
            pendingPrompts[sessionId] = held
        }
    }

    /// Stop a sleeping retry for one session.
    /// - Parameter sessionId: the session whose delivery is no longer wanted.
    private func cancelHeldDelivery(for sessionId: String) {
        heldDeliveries.removeValue(forKey: sessionId)?.task.cancel()
    }

    /// Upload one attachment over the socket that is already open.
    ///
    /// Throws the host's own ``MizarError``; `NOT_IMPLEMENTED` is the one the
    /// composer recognises as "this computer's plugin is too old". The request
    /// bodies are deliberately not logged: a chunk is 128 KiB of base64, and a
    /// log an operator exports is not the place for it.
    ///
    /// - Parameters:
    ///   - data: the bytes.
    ///   - kind: image or file.
    ///   - name: the file name.
    ///   - mediaType: the IANA media type.
    ///   - sessionId: the session the attachment belongs to.
    ///   - progress: called with the fraction sent, on an arbitrary executor.
    /// - Returns: the host's record of the stored attachment.
    func uploadAttachment(
        data: Data,
        kind: AttachmentKind,
        name: String,
        mediaType: String,
        sessionId: String,
        progress: (@Sendable (Double) -> Void)? = nil,
    ) async throws -> AttachmentRef {
        guard let connection else {
            throw MizarError(
                code: "SOCKET_CLOSED",
                message: "the computer is not connected",
                retryable: true,
            )
        }
        let uploader = AttachmentUploader { method, payload in
            try await connection.request(method, payload: payload)
        }
        let ref = try await uploader.upload(
            sessionId: sessionId,
            kind: kind,
            name: name,
            mediaType: mediaType,
            data: data,
            progress: progress,
        )
        log.add(.request, "uploaded \(name) (\(data.count) bytes) -> \(ref.attachmentId)")
        return ref
    }

    /// Dispatch one bridge call for the preview page.
    ///
    /// Deliberately not the generic `call(_:payload:as:)` above: a preview is a
    /// *sequence* of calls whose progress is the point (one `file.stat`, then a
    /// slice per 256 KiB), and the retry that method performs would restart a
    /// half-read document from the beginning. The caller decides what a failure
    /// means — `PreviewCenter` falls back to its cached copy, or says which half
    /// of the link is down.
    ///
    /// - Parameters:
    ///   - method: `file.stat` or `file.read`.
    ///   - payload: the method's arguments.
    /// - Returns: the `result` of the answer.
    /// - Throws: `MizarError` from the host, one raised here when the preview is
    ///   locked out (``previewUnlocked``), or one when there is no socket at all.
    func previewCall(_ method: String, _ payload: JSONValue?) async throws -> JSONValue? {
        // The second guard, beside the one the page draws: a locked feature
        // never reaches the socket, so no state of the UI can make a paid-only
        // method run. Same shape as the activity feed's refusal.
        guard previewUnlocked else {
            let failure = MizarError(
                code: "PREVIEW_LOCKED",
                message: activeEndpoint?.isDirectPath == true
                    ? "the file preview is not available over a P2P direct link"
                    : "the file preview needs a paid account or a local network link",
                retryable: true,
            )
            logRequest(method, payload: payload, since: .now, error: failure)
            throw failure
        }
        guard let connection else {
            let failure = MizarError(
                code: "NO_CONNECTION",
                message: "not connected to the computer",
                retryable: true,
            )
            logRequest(method, payload: payload, since: .now, error: failure)
            throw failure
        }
        let started = ContinuousClock.now
        do {
            let value = try await connection.request(method, payload: payload)
            logRequest(method, payload: payload, since: started, error: nil)
            return value
        } catch {
            logRequest(method, payload: payload, since: started, error: error)
            throw error
        }
    }

    /// The account's token changed, so the socket's identity headers are stale.
    ///
    /// A relay reads its traffic identity from the WebSocket upgrade request and
    /// strips it before forwarding, so the only way to change it is a new socket.
    /// This is a reconnect, not a disconnect-and-wait: the session list is bigger
    /// than a dropped socket should cost either way, but a phone that has just
    /// signed in should show as signed in on the relay within a round trip.
    private func accountIdentityChanged() {
        guard host != nil else { return }
        accountReconnectTask?.cancel()
        accountReconnectTask = Task { [weak self] in
            guard let self else { return }
            // A sign-in while the app is on the failure screen still counts: the
            // reconnect is what moves it back to ready.
            guard await self.reconnect(patient: false) else { return }
            await self.refreshSessions()
            // The new identity may carry a different plan, and the tunnel's
            // relay should follow it. Done after the reconnect: `relay.set`
            // needs a live socket.
            await self.syncRelayTier()
        }
    }

    /// The reconnect a sign-in or sign-out asked for, kept so a second change
    /// cannot stack two redials on one socket.
    private var accountReconnectTask: Task<Void, Never>?

    // MARK: - Relay tier

    /// A plan change may mean the tunnel belongs on the other relay.
    private func accountPlanChanged() {
        relaySyncTask?.cancel()
        relaySyncTask = Task { [weak self] in
            await self?.syncRelayTier()
        }
    }

    /// Ask the host to put its tunnel on the relay this account's tier pays for.
    ///
    /// The host redials; this side only says which of the two public relays the
    /// phone should be reached through. A host from before `relay.set` answers
    /// `NOT_IMPLEMENTED` and is left alone. The pairing's stored base URL is
    /// updated from the answer so the next reconnect dials the right relay, and
    /// a relayed socket is redialled once the host has had time to move.
    func syncRelayTier() async {
        // A relay tier is a fact about a computer's tunnel. The on-device agent
        // has no tunnel, and asking it would read `host.info` for an answer it
        // does not have.
        guard !isLocalAgentMode else { return }
        guard let connection, phase == .ready else { return }
        guard let info = try? await connection.call("host.info", as: HostInfo.self) else { return }
        // Learned on every ready socket rather than at pairing: the host may
        // have been upgraded, or its engine may have failed to start at pairing
        // time and started since. A pairing that gains an identity gains a route
        // without being re-paired, and one that loses it falls back to the relay
        // because `.p2p` is derived from this field and disappears with it.
        if let endpointId = info.netEndpointId, !endpointId.isEmpty {
            await rememberDirectPathIdentity(endpointId)
        }
        // The computer list draws these under the machine's name. Learned on
        // every ready socket for the same reason as the direct-path identity:
        // the host may have been upgraded since the pairing, and the value is
        // written into the pairing so an offline computer keeps its labels.
        if let desktop = info.desktop, !desktop.isEmpty {
            await rememberDesktopIdentity(desktop)
        }
        // Which agents this computer serves, and which one this socket is bound
        // to. Read on every ready socket, like the identity and the desktop
        // label above, because a host upgraded mid-pairing can start serving
        // three agents without the phone being re-paired.
        if let engines = info.engines {
            await rememberEngines(engines.map(\.id))
            await adoptEngineScope(info.engine.flatMap(AgentEngine.init(rawValue:)))
        }
        guard let relay = info.relay else { return }
        let desired = RelayTier.baseURL(paid: account.isPaid)
        if RelayTier.canonicalOrigin(relay.url) == desired {
            // The host is already on the right relay. The phone's stored base
            // URL can still be stale -- a fallback may have landed on the
            // alternate -- so repair that from the host's own answer.
            if let baseURL = relay.baseURL, baseURL != host?.baseURL {
                await rememberRelayBaseURL(baseURL)
            }
            return
        }
        do {
            let result = try await connection.call(
                "relay.set",
                payload: .object(["url": .string(desired)]),
                as: RelaySetResult.self,
            )
            let baseURL = result.baseURL
                ?? host?.baseURL.flatMap { RelayTier.rebased($0, onto: result.url) }
            if let baseURL { await rememberRelayBaseURL(baseURL) }
            log.add(.connection, "relay: host moved to \(result.url)")
            scheduleRelayReconnect(to: baseURL)
        } catch {
            // An older host answers NOT_IMPLEMENTED: it predates relay tiers and
            // is already where its configuration says, so there is nothing to
            // report. Anything else is a connection failure the next request
            // will surface; this must not take the screen down.
            if let failure = error as? MizarError, failure.known == .notImplemented { return }
            log.add(
                .connection,
                "relay: could not move the host to \(desired) — "
                    + Self.describe(error, authority: desired),
            )
        }
    }

    /// Remember which agents this computer said it serves.
    ///
    /// Stored on the pairing so the choice can be offered while the computer is
    /// offline -- and so a tap can ask "which agent?" *before* a socket opens,
    /// which is the only way the merged list never appears at all.
    ///
    /// - Parameter engines: the wire names, in the host's order.
    private func rememberEngines(_ engines: [String]) async {
        guard var current = host else { return }
        guard current.knownEngines != engines else { return }
        current = current.remembering(engines: engines)
        host = current
        if let index = hosts.firstIndex(where: { $0.hostId == current.hostId }) {
            hosts[index] = current
        }
        try? await credentials.save(current)
        log.add(.connection, "agents: this computer serves \(engines.joined(separator: ", "))")
    }

    /// Take the computer's own word for which agent this connection is bound to.
    ///
    /// The phone's stored choice is an intention; this is what the arriving rows
    /// were actually filtered by, because a token the relay minted is scoped on
    /// the computer's side. A phone whose stored choice and token disagree would
    /// otherwise filter by the wrong one and show an empty list that is not
    /// empty.
    ///
    /// - Parameter engine: the agent the host named, or `nil` for "all agents".
    private func adoptEngineScope(_ engine: AgentEngine?) async {
        guard engine != engineScope else { return }
        engineScope = engine
        // The lists on screen were filtered by the old answer. Re-filter rather
        // than wait for the next refresh: one of them may be wrong now, and the
        // other is already in memory.
        sessions = Self.scoped(sessions, to: engine)
        if let workspaces { self.workspaces = Self.scoped(workspaces, to: engine) }
        guard var current = host else { return }
        let wire = engine?.rawValue
        guard current.engine != wire else { return }
        current = current.opened(on: wire)
        host = current
        if let index = hosts.firstIndex(where: { $0.hostId == current.hostId }) {
            hosts[index] = current
        }
        try? await credentials.save(current)
        log.add(.connection, "agent: this connection is \(engine?.title ?? "all agents")")
    }

    /// The agents this computer offers a choice of.
    ///
    /// Empty when there is nothing to choose. The pairing remembers the answer
    /// from the last connection, so this works while the computer is offline.
    var engineChoices: [AgentEngine] {
        guard !isLocalAgentMode, let host else { return [] }
        return host.engineChoices.compactMap(AgentEngine.init(rawValue:))
    }

    /// Open this computer as one agent, or as all of them.
    ///
    /// A live connection is redialled, because the choice travels at `hello` and
    /// the host would otherwise keep answering for the agent it was told about
    /// when the socket opened.
    ///
    /// - Parameters:
    ///   - engine: the agent to show, or `nil` for every agent the computer has.
    ///   - hostId: the computer. Defaults to the open one.
    func chooseEngine(_ engine: AgentEngine?, for hostId: String? = nil) async {
        guard let hostId = hostId ?? host?.hostId else { return }
        guard let current = hosts.first(where: { $0.hostId == hostId }) else { return }
        // Tapping the agent that is already on screen is not a reason to drop a
        // working socket. Compared against the effective scope rather than the
        // record, because those differ for a connection the relay scoped -- and
        // only for the computer that is open: choosing for another one is a
        // stored preference, not a comparison with what is on screen.
        if host?.hostId == hostId, engine == engineScope { return }
        let updated = current.opened(on: engine?.rawValue)
        if let index = hosts.firstIndex(where: { $0.hostId == hostId }) { hosts[index] = updated }
        if host?.hostId == hostId { host = updated }
        try? await credentials.save(updated)
        // Asked for a computer while another is open: storing the choice is the
        // whole of it. Except under the on-device agent, where `host` is nil by
        // design (``enterLocalAgent``), so "not the open computer" cannot be
        // told from "nothing is open" -- and a tap there means leave the local
        // agent and open this computer, which ``open(hostId:)`` already does.
        guard host?.hostId == hostId || isLocalAgentMode else { return }
        await open(hostId: hostId)
    }

    /// Persist the identity the host punches under.
    ///
    /// - Parameter endpointId: the host's direct-path identity, from `host.info`.
    private func rememberDirectPathIdentity(_ endpointId: String) async {
        guard let host, host.netEndpointId != endpointId else { return }
        let updated = host.remembering(netEndpointId: endpointId)
        self.host = updated
        if let index = hosts.firstIndex(where: { $0.hostId == updated.hostId }) { hosts[index] = updated }
        try? await credentials.save(updated)
        log.add(.connection, "direct path: this computer can be punched")
    }

    /// Persist what this computer is, for the computer list.
    ///
    /// - Parameter desktop: the host's answer from `host.info`.
    private func rememberDesktopIdentity(_ desktop: HostDesktop) async {
        guard let host, host.desktop != desktop else { return }
        let updated = host.remembering(desktop: desktop)
        self.host = updated
        if let index = hosts.firstIndex(where: { $0.hostId == updated.hostId }) { hosts[index] = updated }
        try? await credentials.save(updated)
        log.add(.connection, "desktop: this computer is \(desktop.os) · \(desktop.client)")
    }

    /// Persist the relay base URL the host reported or promised.
    private func rememberRelayBaseURL(_ baseURL: String) async {
        guard let host, host.baseURL != baseURL else { return }
        let moved = host.moved(toRelay: baseURL)
        self.host = moved
        if let index = hosts.firstIndex(where: { $0.hostId == moved.hostId }) { hosts[index] = moved }
        try? await credentials.save(moved)
    }

    /// Redial once the host has had time to move its tunnel.
    ///
    /// The answer travelled over the tunnel the host is about to replace, so the
    /// host waits a beat before moving. Dialling exactly the new room avoids
    /// first trying the relay the host just left.
    private func scheduleRelayReconnect(to baseURL: String?) {
        guard let activeEndpoint, case .relay = activeEndpoint, let baseURL else { return }
        relaySwitchTask?.cancel()
        relaySwitchTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            guard await self.reconnect(over: .relay(baseURL: baseURL)) else { return }
            await self.refreshSessions(reconnectingIfNeeded: false)
            await self.refreshInteractions()
        }
    }

    /// Apply a `relay.changed` event another device asked for.
    private func applyRelayChanged(_ data: JSONValue) async {
        guard let changed = try? data.decoded(as: HostRelay.self) else { return }
        let baseURL = changed.baseURL
            ?? host?.baseURL.flatMap { RelayTier.rebased($0, onto: changed.url) }
        if let baseURL { await rememberRelayBaseURL(baseURL) }
        scheduleRelayReconnect(to: baseURL)
    }

    /// The relay switch or sync in flight, so a second change cannot stack two
    /// redials on one socket.
    private var relaySyncTask: Task<Void, Never>?
    private var relaySwitchTask: Task<Void, Never>?

    /// Start a session in a directory.
    ///
    /// - Parameter cwd: the directory to work in.
    /// - Returns: the new session's id, or `nil` when the host refused.
    func createSession(cwd: String, select: Bool = true) async -> String? {
        guard let connection else { return nil }
        let payload = JSONValue.object(["cwd": .string(cwd)])
        do {
            let result = try await loggedCall("session.create", payload: payload, on: connection, as: CreateSessionResult.self)
            await refreshSessions()
            if select { selectedSessionId = result.sessionId }
            return result.sessionId
        } catch {
            phase = .failed(Self.describe(error, authority: host?.authority))
            return nil
        }
    }

    /// Branch through the selected turn's exact inclusive log boundary.
    /// A host or selection change while the request is away must not navigate
    /// the operator back to a conversation they have already left.
    func forkSession(sessionId: String, atSeq: Int) async throws {
        guard let connection else {
            throw NSError(domain: "MizarBranch", code: 1, userInfo: [
                NSLocalizedDescriptionKey: String(localized: "Not connected to the computer."),
            ])
        }
        let epoch = connectionEpoch
        let navigation = selectionGeneration
        let hostId = host?.hostId
        let payload = JSONValue.object([
            "sessionId": .string(sessionId),
            "atSeq": .number(Double(atSeq)),
        ])
        struct ForkResult: Decodable, Sendable { let sessionId: String }
        let result = try await loggedCall("session.fork", payload: payload, on: connection, as: ForkResult.self)
        guard !Task.isCancelled, connectionEpoch == epoch, host?.hostId == hostId,
              selectionGeneration == navigation, selectedSessionId == sessionId else { return }
        await refreshSessions()
        guard !Task.isCancelled, connectionEpoch == epoch, host?.hostId == hostId,
              selectionGeneration == navigation, selectedSessionId == sessionId else { return }
        guard !result.sessionId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NSError(domain: "MizarBranch", code: 2, userInfo: [
                NSLocalizedDescriptionKey: String(localized: "The conversation was not branched. Try again."),
            ])
        }
        selectedSessionId = result.sessionId
    }

    /// Start a session in a directory and give it its first prompt, in that
    /// order, before opening it.
    ///
    /// The order is the point. Selecting the session first -- which is what
    /// `createSession` does -- swaps the screen the operator typed on for the
    /// conversation while the send is still in flight, and the screen that was
    /// going to watch for the prompt arriving is gone. Sent first, the prompt is
    /// left in ``pendingFirstPrompt`` for the conversation to pick up and watch
    /// for itself.
    ///
    /// - Parameters:
    ///   - cwd: the directory to work in.
    ///   - prompt: what to say first.
    /// - Returns: the new session's id, or `nil` when the host refused either.
    @discardableResult
    func startSession(cwd: String, prompt: String) async -> String? {
        guard let sessionId = await createSession(cwd: cwd, select: false) else { return nil }
        // The model chosen on the home screen, applied to the session it was
        // chosen for. The host creates a session on its own default and only
        // then accepts a switch, so this is the earliest it can happen -- and it
        // is best effort: a refusal leaves the default in place, and the
        // conversation's own bar then names what is actually answering rather
        // than repeating a choice that did not take.
        if let choice = newSessionModel {
            _ = await setModel(
                provider: choice.provider,
                model: choice.model,
                effort: choice.effort,
                sessionId: sessionId,
            )
        }
        guard await sendPrompt(prompt, to: sessionId) else {
            // The session exists and is empty; open it so the operator can see
            // it and try again from there, with their words still to hand.
            selectedSessionId = sessionId
            return nil
        }
        pendingFirstPrompt[sessionId] = prompt
        selectedSessionId = sessionId
        return sessionId
    }

    /// Create a workspace folder under the on-device agent's root.
    ///
    /// The remote half of the app can only *use* a directory the computer
    /// already has. The on-device agent owns its root, so a workspace here is
    /// something this phone can make: one folder, named by the operator,
    /// directly in the folder the Files app shows.
    ///
    /// - Parameter name: the folder name. No slashes; the kernel refuses what
    ///   cannot be a folder.
    /// - Returns: the workspace, as the kernel reports it.
    @discardableResult
    func createLocalWorkspace(name: String) async throws -> WorkspaceRow {
        guard let connection, isLocalAgentMode else { throw LocalWorkspaceFailure.notConnected }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw LocalWorkspaceFailure.emptyName }
        // Asked before the kernel is: "already exists" is a sentence this app
        // has words for, and the kernel's own message is a diagnostic
        // (`workspace.create: "Projects" already exists`) that reads like a bug
        // report on screen.
        if workspaceChoices.contains(where: { $0.title == trimmed }) {
            throw LocalWorkspaceFailure.duplicateName
        }
        let payload = JSONValue.object(["name": .string(trimmed)])
        let result = try await loggedCall(
            "workspace.create",
            payload: payload,
            on: connection,
            as: WorkspaceCreateResult.self,
        )
        // The session list and the workspace registry are one answer on this
        // host; reading both is what makes the new folder appear with the
        // others rather than only after a manual refresh.
        await refreshSessions(reconnectingIfNeeded: false)
        return result.workspace
    }

    /// Why a workspace could not be made.
    enum LocalWorkspaceFailure: LocalizedError {
        case notConnected
        case emptyName
        case duplicateName

        var errorDescription: String? {
            switch self {
            case .notConnected: String(localized: "The on-device agent is not connected.")
            case .emptyName: String(localized: "Type a workspace name.")
            case .duplicateName: String(localized: "A workspace with that name already exists.")
            }
        }
    }

    /// The first prompt of a session started from the home screen, waiting for
    /// its conversation to open and watch for it. Taken once.
    var pendingFirstPrompt: [String: String] = [:]

    /// Ask the host to stop the current turn.
    func cancelTurn(sessionId: String) async {
        guard let connection else { return }
        let payload = JSONValue.object(["sessionId": .string(sessionId)])
        _ = try? await loggedCall("session.cancel", payload: payload, on: connection, as: AcceptanceResult.self)
    }

    // MARK: - Full-detail activity (unlocked accounts)

    /// The running turn's process details, accumulated per session.
    ///
    /// A feed, not the last answer. The poll merges its newest window into the
    /// feed and the operator's scrolling prepends older pages, so the list on
    /// screen only ever grows -- replacing it with each answer would re-animate
    /// every row once a poll and throw away the older pages the operator had
    /// asked for. See ``ActivityFeed`` for the merge rules and their tests.
    ///
    /// Only ever populated for an **unlocked** account (paid, or connected over
    /// a LAN link) and only while a turn is running. A locked account never
    /// fills this, because it never asks: the methods below return before
    /// touching the socket. That is a product boundary, not a UI one -- a screen
    /// that hides the detail but still spends the bandwidth is the wrong half of
    /// the trade.
    ///
    /// Nothing here is persisted. The summary-only history is what the phone
    /// keeps; this is a live view of a turn that is happening now, and when the
    /// turn ends the detail goes with it.
    private var sessionActivity: [String: ActivityFeed] = [:]

    /// Bumped whenever the accumulated detail changes.
    ///
    /// The detail list is read through a method, and the running row needs a
    /// direct observable dependency to redraw when a window lands or a page is
    /// prepended. The revision is that dependency; it is deliberately an
    /// integer, not a copy of the feed. It is bumped only when there is a real
    /// change, so a poll that repeats what is held does not redraw the area.
    private(set) var activityRevision = 0

    /// How many recent entries one poll asks for.
    ///
    /// Small on purpose: the newest few dozen rows are what the window follows,
    /// and older rows are a deliberate walk backwards. Asking for the host's
    /// default 200 every second is most of this feature's traffic spent on rows
    /// nobody is looking at.
    private static let activityLatestEntries = 60

    /// How many entries one lazy older page asks for.
    private static let activityOlderEntries = 100

    /// Sessions with a full-detail window read in flight.
    ///
    /// The poll is a round trip, so without this a slow host would have two
    /// reads of the same session in flight and the slower, older answer could
    /// land last.
    private var activityReads: Set<String> = []

    /// Sessions with an older page in flight, so a scroll that keeps bouncing
    /// at the top cannot stack pages.
    private var activityOlderReads: Set<String> = []

    /// The accumulated details for a session, for the running-turn row.
    ///
    /// - Parameter sessionId: the session.
    /// - Returns: the rows, oldest first, or `nil` when there are none, or when
    ///   the full detail is not unlocked. The check is repeated here so a caller
    ///   cannot draw a detail area the account has no right to by reading a stale
    ///   cache; ``advancedFeaturesUnlocked`` is what makes a LAN link entitled
    ///   to it without a paid plan.
    func activity(for sessionId: String) -> [ActivityEntry]? {
        guard advancedFeaturesUnlocked else { return nil }
        return sessionActivity[sessionId]?.entries
    }

    /// Whether older rows may still be read from the host.
    ///
    /// - Parameter sessionId: the session.
    /// - Returns: whether a scroll to the top of the detail area is worth a
    ///   request.
    func activityHasOlder(for sessionId: String) -> Bool {
        guard advancedFeaturesUnlocked else { return false }
        return sessionActivity[sessionId]?.canLoadOlder ?? false
    }

    /// Read the running turn's latest process details.
    ///
    /// Unlocked accounts only -- paid, or connected over a LAN link. Called on a
    /// poll by the running-turn row itself (see `TurnActivitySummary`), which is
    /// where "while it is running" is decided; this method is the fetch, not the
    /// schedule.
    ///
    /// Deliberately not through `loggedCall`: that writes a request entry into the
    /// log, and a log line every second or two for the whole of a turn would bury
    /// the events the log export exists for.
    ///
    /// A failure is not shown and does not erase anything. The last answer stays
    /// on screen: the detail is decoration on a row that already says how long
    /// the turn has been going, and a dropped read is not news.
    ///
    /// - Parameter sessionId: the session to read.
    func refreshActivity(for sessionId: String) async {
        guard advancedFeaturesUnlocked, let connection, !activityReads.contains(sessionId) else { return }
        activityReads.insert(sessionId)
        defer { activityReads.remove(sessionId) }
        do {
            let result = try await connection.sessionActivity(
                sessionId: sessionId,
                maxEntries: Self.activityLatestEntries,
            )
            // An answer about another session is not this session's detail. The
            // host echoes the id; trusting it is one cheap check against a
            // mis-routed answer landing under the wrong row.
            guard result.sessionId.isEmpty || result.sessionId == sessionId else { return }
            guard let turn = result.turn else {
                // The turn ended (or was cancelled) between polls. The detail
                // area has nothing left to describe, so it goes -- not faded,
                // gone, because there is no turn for it to belong to.
                clearActivity(for: sessionId)
                return
            }
            if var feed = sessionActivity[sessionId], feed.turn == turn {
                let changed = feed.merge(latest: result)
                sessionActivity[sessionId] = feed
                if changed { activityRevision &+= 1 }
            } else if let feed = ActivityFeed(latest: result) {
                // A new turn (or the first read of this one): its process is a
                // different list, not more rows on the old one.
                sessionActivity[sessionId] = feed
                activityRevision &+= 1
            }
        } catch {
            // Keep what is on screen; see the doc comment.
        }
    }

    /// Read one older page of the running turn's details.
    ///
    /// Called when the detail area is scrolled to its top. The page goes in
    /// front of what is held; a page that adds nothing ends the walk (an older
    /// host ignores the request and answers the newest window again), which is
    /// the no-progress guard that keeps a scroll at the top from looping.
    ///
    /// A failure leaves the feed as it was and shows nothing: the rows already on
    /// screen are still true, and the next scroll to the top asks again.
    ///
    /// - Parameter sessionId: the session to extend.
    /// - Returns: whether the page added rows.
    @discardableResult
    func loadOlderActivity(for sessionId: String) async -> Bool {
        guard advancedFeaturesUnlocked, let connection,
              let cursor = sessionActivity[sessionId]?.olderCursor,
              let turn = sessionActivity[sessionId]?.turn,
              sessionActivity[sessionId]?.canLoadOlder == true,
              !activityOlderReads.contains(sessionId)
        else { return false }
        activityOlderReads.insert(sessionId)
        defer { activityOlderReads.remove(sessionId) }
        do {
            let result = try await connection.sessionActivity(
                sessionId: sessionId,
                maxEntries: Self.activityOlderEntries,
                beforeSeq: cursor,
                turn: turn,
            )
            // Re-read the feed: a poll may have merged a window while this page
            // was in flight, and the newer tail must not be overwritten.
            guard var feed = sessionActivity[sessionId], feed.turn == turn else { return false }
            let grew = feed.prepend(older: result)
            sessionActivity[sessionId] = feed
            activityRevision &+= 1
            return grew
        } catch {
            log.add(.request, "activity older page failed for \(sessionId)")
            return false
        }
    }

    /// Forget a session's full detail.
    ///
    /// Called when the running-turn row collapses, is scrolled away, or the
    /// session turns out to have stopped. Keeps a paid feed from outliving the
    /// turn it describes.
    ///
    /// - Parameter sessionId: the session to forget.
    func clearActivity(for sessionId: String) {
        guard sessionActivity[sessionId] != nil else { return }
        var next = sessionActivity
        next.removeValue(forKey: sessionId)
        sessionActivity = next
        activityRevision &+= 1
    }

    /// Switch the session's model, and optionally its reasoning effort.
    ///
    /// The choice is shown before the host agrees, and taken back when it does
    /// not. Both halves are deliberate. Shown first, because the round trip is
    /// real and a picker that sat blank until it landed read as not working --
    /// and because the host has no "what is this session using" read on this side
    /// of the protocol, so what this app asked for is the only thing there is to
    /// show. Taken back after, because the failure used to be swallowed: a switch
    /// the host refused was drawn as applied for the rest of the process, and
    /// there was nothing on screen that could contradict it. That is a lie about
    /// the operator's own session, and it is the kind that gets acted on.
    ///
    /// - Parameters:
    ///   - provider: the provider id.
    ///   - model: the model id.
    ///   - effort: the reasoning level, or `nil` for the provider default.
    ///   - sessionId: the session to change.
    /// - Returns: whether the host agreed. The picker keeps itself open when it
    ///   did not, so the operator sees the choice go back rather than watching a
    ///   sheet close over a switch that never happened.
    @discardableResult
    func setModel(provider: String, model: String, effort: String?, sessionId: String) async -> Bool {
        // Remembered before the call, not after. The host has no "what is this
        // session using" read on the phone's side of the protocol, so this is
        // what lets the picker show a checkmark when it is reopened -- without
        // it the picker started blank every time, and there was no way to tell
        // what was selected.
        let previous = modelChoice[sessionId]
        modelChoice[sessionId] = ModelChoice(provider: provider, model: model, effort: effort)
        guard let connection else {
            // Nothing was asked, so nothing may be shown as applied. The picker
            // is open on a screen with no socket under it, which is a state the
            // operator can be in: this is not a switch that failed, it is one
            // that was never sent.
            modelChoice[sessionId] = previous
            lastError = String(localized: "Could not switch model")
            return false
        }
        var fields: [String: JSONValue] = [
            "sessionId": .string(sessionId),
            "provider": .string(provider),
            "model": .string(model),
        ]
        if let effort { fields["reasoningEffort"] = .string(effort) }
        do {
            _ = try await loggedCall(
                "session.model.set",
                payload: .object(fields),
                on: connection,
                as: SelectModelResult.self,
            )
            return true
        } catch {
            // Only if it is still the choice being taken back. A read cannot
            // overtake this -- the actor runs one call at a time -- but the
            // operator can choose again while this one is in flight, and
            // restoring an older value over a newer one would be a second lie in
            // the opposite direction.
            if modelChoice[sessionId] == ModelChoice(provider: provider, model: model, effort: effort) {
                modelChoice[sessionId] = previous
            }
            let reason = Self.describe(error)
            if !reason.isEmpty { lastError = reason }
            log.add(
                .request,
                "model switch refused: \(provider)/\(model)"
                    + (reason.isEmpty ? "" : " -- \(reason)"),
            )
            return false
        }
    }

    /// Presets the host accepted here, ahead of the projection that confirms
    /// them.
    ///
    /// The host confirms a switch by its `permissions` projection changing, not
    /// by the command's return value -- the bridge says so in as many words --
    /// so between the call returning and the next `session.stats` the screen
    /// holds the old preset. The picker is dismissed in that window, and
    /// reopening it read the old frame: choose a preset, reopen, see the old one
    /// ticked. This map is what the screen reads until the host's answer lands.
    private var appliedPermissions: [String: String] = [:]

    /// The preset to show for a session.
    ///
    /// - Parameters:
    ///   - sessionId: the session.
    ///   - reported: the last figure the host's stats frame carried.
    /// - Returns: a preset the host accepted here and has not yet confirmed,
    ///   else the host's own answer.
    func permissionPreset(for sessionId: String, reported: String?) -> String? {
        appliedPermissions[sessionId] ?? reported
    }

    /// Switch the session's permission preset.
    ///
    /// A success is recorded locally before the host's projection is re-read:
    /// see ``appliedPermissions``. A refusal comes back as `nil`, and the picker
    /// shows it rather than closing on a switch that did not happen.
    ///
    /// - Parameters:
    ///   - preset: the preset value.
    ///   - sessionId: the session to change.
    /// - Returns: the host's report, or `nil` when it could not be reached.
    func setPermission(_ preset: String, sessionId: String) async -> SetPermissionResult? {
        guard let connection else { return nil }
        let payload = JSONValue.object([
            "sessionId": .string(sessionId),
            "preset": .string(preset),
        ])
        guard let result = try? await loggedCall(
            "session.permission.set",
            payload: payload,
            on: connection,
            as: SetPermissionResult.self,
        ), result.commandResult.succeeded else {
            log.add(.request, "permission switch refused: \(preset)")
            return nil
        }
        appliedPermissions[sessionId] = preset
        // Ask for the frame that actually confirms the switch. Best effort: the
        // override above already draws the right answer if this read fails.
        _ = await stats(for: sessionId)
        return result
    }

    /// The host's answer to `session.archive`.
    private struct ArchiveSessionResult: Decodable, Sendable {
        let archived: Bool
    }

    /// Archive a session on the computer, and take it off this phone's list.
    ///
    /// Non-destructive on the host: the plugin archives without stopping work,
    /// so a session whose turn is running is refused and the refusal is shown.
    /// A long-press is not the moment to silently kill an agent mid-turn.
    ///
    /// The row is removed locally before the list is re-read, so the menu action
    /// has a visible effect immediately; the read is what makes the workspace
    /// counts, the pending set and the stored index agree with the host. If the
    /// host refuses, nothing is removed and ``lastError`` carries the reason to
    /// the banner over the list.
    ///
    /// - Parameter sessionId: the session to archive.
    /// - Returns: whether the host accepted it.
    @discardableResult
    func archiveSession(_ sessionId: String) async -> Bool {
        guard let connection else {
            lastError = "Not connected to the computer."
            return false
        }
        let payload = JSONValue.object(["sessionId": .string(sessionId)])
        do {
            _ = try await loggedCall(
                "session.archive",
                payload: payload,
                on: connection,
                as: ArchiveSessionResult.self,
            )
        } catch {
            let message = Self.describe(error, authority: host?.authority ?? host?.baseURL)
            lastError = message.isEmpty ? String(localized: "The session was not archived.") : message
            log.add(.request, "archive refused for \(sessionId)")
            return false
        }
        // The host is the authority, and `refreshSessions` below is its answer.
        // Removing first is what lets the row leave while that read is in flight.
        if selectedSessionId == sessionId { selectedSessionId = nil }
        titles.removeValue(forKey: sessionId)
        sessions.removeAll { $0.sessionId == sessionId }
        await persistIndex()
        await refreshSessions()
        return true
    }

    /// Forget every pairing and return to the pairing screen.
    ///
    /// Distinct from forgetting one machine: this is "start over", which is what
    /// a reinstall or a shared phone needs.
    func unpair() async {
        // Before the socket goes: this is the last chance to tell the host that
        // this phone should stop being woken for a machine it is leaving.
        await forgetPushRegistration()
        interactionPoll?.cancel()
        eventListener?.cancel()
        await connection?.disconnect()
        connection = nil
        welcome = nil
        sessions = []
        selectedSessionId = nil
        // Captured first. Iterating `hosts` after `hosts = []` walked an empty
        // array, so "start over" left every stored session list on disk.
        let forgetting = hosts.map(\.hostId)
        host = nil
        hosts = []
        LastOpenedHostStore.store(nil)
        try? await credentials.clear()
        for forgotten in forgetting { await indexStore.remove(hostId: forgotten) }
        titles = [:]
        workspaces = nil
        hasStoredIndex = false
        // Every host-scoped value, for every machine at once. `connection` is
        // already nil, so none of these is readable any more -- dropping them is
        // what keeps them out of the next pairing's export.
        modelChoice = [:]
        newSessionModel = nil
        modelCatalogState.clear()
        permissionCatalogState.clear()
        pendingState.clear()
        recentHostEventState.clear()
        phase = .unpaired
        log.add(.connection, "unpaired: every stored credential and index removed")
    }

    // MARK: - The log export

    /// Write everything this phone knows into a zip, and hand back the file.
    ///
    /// Everything the archive needs is gathered here, at the moment the button is
    /// tapped: the log so far, the build and the phone, the switch positions, and
    /// what the host last said. Nothing is cached for it, because the interesting
    /// report is always about what is happening now.
    ///
    /// A failure is written to the log and returned as `nil` rather than thrown
    /// at the view: the screen has nothing useful to say about the temporary
    /// directory being full, and an alert over a settings list is worse than a
    /// row that says the export did not happen.
    ///
    /// - Returns: the archive, or `nil` when it could not be written.
    @discardableResult
    func exportLogs() async -> LogArchive? {
        let environment = await AppEnvironment.facts()
        do {
            let archive = try LogArchiveWriter.write(
                records: log.records,
                environment: environment,
                settings: settings.values,
                host: hostSummary,
                // The temporary directory, deliberately: this is a copy of the
                // app's state and it is meant to leave the phone. Keeping it
                // would leave a second, longer-lived log on disk with no way to
                // delete it from the screen that made it.
                to: FileManager.default.temporaryDirectory,
            )
            lastLogExport = archive
            log.add(
                .app,
                "log export: \(archive.fileName), \(archive.fileCount) files, "
                    + "\(archive.byteCount) bytes, \(archive.recordCount) records",
            )
            return archive
        } catch {
            log.add(.app, "log export failed: \(Self.describe(error))")
            lastLogExport = nil
            return nil
        }
    }

    /// What the host last said, as the archive describes it.
    ///
    /// Built by hand rather than by encoding the frames the app holds, and that
    /// is the point: a `WelcomeFrame` carries the device id, a `PairedHost`
    /// carries the device token, and a dump of either would put a credential into
    /// a file whose entire purpose is to be sent to somebody else. Every field
    /// here is one somebody chose to include.
    var hostSummary: HostSummary {
        HostSummary(
            connected: isConnected,
            phase: phaseName,
            current: host.map(machine),
            pairedHosts: hosts.map(machine),
            protocolVersion: welcome?.protocolVersion,
            sessionCount: sessions.count,
            titledSessionCount: titles.count,
            // `nil` stays `nil`: "the computer has not said how many workspaces it
            // has" and "it has none" are different answers here too.
            workspaceCount: workspaces?.count,
            lastError: lastError,
            pendingApprovals: (pending?.approvals ?? []).map { approval in
                HostSummary.Approval(
                    requestId: approval.requestId,
                    sessionId: approval.sessionId,
                    toolName: approval.toolName,
                    // The presentation text if the tool supplied one, else the
                    // raw reason: the same choice the card on screen makes, so
                    // the archive describes what the operator was looking at.
                    reason: approval.reasonText(preferring: Locale.preferredLanguages.first ?? "en"),
                    waitingSeconds: Date(timeIntervalSince1970: approval.requestedAt / 1000)
                        .distance(to: Date())
                        .rounded(),
                )
            },
            pendingQuestions: (pending?.questions ?? []).map { question in
                HostSummary.Question(
                    callId: question.callId,
                    sessionId: question.sessionId,
                    count: question.questions.count,
                    // Shortened, because this is a summary and not a transcript.
                    // The question is on screen; what the archive needs is enough
                    // to recognise which one it was.
                    firstPrompt: question.questions.first.map { String($0.question.prefix(120)) },
                )
            },
            recentEvents: recentHostEventsForArchive,
        )
    }

    /// Where the app is in its life, as a word the archive can carry.
    var phaseName: String {
        switch phase {
        case .launching: "launching"
        case .unpaired: "unpaired"
        case .connecting: "connecting"
        case .ready: "ready"
        case .failed: "failed"
        }
    }

    /// One machine, as the archive describes it.
    /// - Parameter paired: the pairing.
    /// - Returns: the machine, and never its token.
    private func machine(_ paired: PairedHost) -> HostSummary.Machine {
        // The live route is recorded for the machine in use and for no other: a
        // second pairing's address is whatever it was paired with, which is a
        // different fact and a misleading one if it is labelled "in use".
        let described = paired.hostId == host?.hostId ? activeEndpoint.map(Self.routeDescription) : nil
        return HostSummary.Machine(
            hostId: paired.hostId,
            name: paired.label ?? paired.hostName,
            route: described?.name ?? (paired.authority != nil ? "direct (not in use)" : "relay (not in use)"),
            address: described?.address ?? paired.authority ?? paired.baseURL,
            pairedAt: paired.pairedAt,
        )
    }

    /// Refresh the session list.
    func refreshSessions() async {
        await refreshSessions(reconnectingIfNeeded: true)
    }

    // MARK: - The operator's own network

    /// How long a LAN probe waits for a host that may not be there.
    ///
    /// Short on purpose. The probe is one of several, it is only ever a guess
    /// about a network, and every second it spends on an address that is not
    /// the computer is a second the refresh it precedes has not started.
    private static let lanProbeTimeout: TimeInterval = 2.5

    /// The operator asked for a refresh.
    ///
    /// Every manual refresh asks the LAN question first. The relay is the route
    /// that works from anywhere, which is exactly why a phone ends up on it and
    /// stays there: a reconnect dials whichever route worked last, and coming
    /// home does not change that by itself. The scan is best effort and silent
    /// when it finds nothing -- the read it precedes is the answer the operator
    /// actually asked for.
    func manualRefresh() async {
        let askedTheLAN = settings.values.localNetworkFirst
        let switched = await scanForLocalNetwork()
        if askedTheLAN, !switched, connection == nil, activeEndpoint?.isLocalNetwork == true {
            // The scan just probed the local address and it did not answer, and
            // there is no socket to refresh. Dial the relay first rather than
            // making the refresh below spend another direct timeout on the
            // address the scan has already ruled out.
            _ = await reconnect(preferringRelay: true)
        }
        await refreshSessions()
    }

    /// Reconnect because the operator asked for it.
    ///
    /// The same route policy as a refresh: with local-network priority on, the
    /// LAN question is asked first, and a hit *is* the reconnect -- the scan
    /// dials the address it found. With it off, the button dials the stored
    /// routes straight away, which is the fast path the transfer setting is
    /// for.
    ///
    /// - Parameter patient: whether to keep trying long enough to outlast a
    ///   phone that has lost its network.
    /// - Returns: whether a connection is now open.
    @discardableResult
    func reconnectFromUser(patient: Bool = true) async -> Bool {
        if settings.values.localNetworkFirst, await scanForLocalNetwork() {
            return true
        }
        return await reconnect(patient: patient)
    }

    /// A transport switch moved, and the answer is now rather than later.
    ///
    /// The two switches are forbidding a *route*, not expressing a preference
    /// about the next reconnect, so a link that is using the route that was just
    /// switched off is closed here -- immediately, while the operator is still
    /// looking at the toggle -- and the redial that follows can only use what
    /// remains (`RoutePolicy` is what decides, in both places). Turning one on
    /// is the same news in reverse: the LAN watch starts again, and the local
    /// network is asked once so the switch feels applied rather than
    /// remembered.
    ///
    /// Called from the settings screen's own `onChange`, which is the only thing
    /// that can flip these.
    func transportPreferenceChanged() async {
        updateLanWatch()
        // Turning 局域网优先 on while the relay is carrying the socket: ask now,
        // because that is the whole point of the switch. The scan is the thing
        // that moves the pairing, and it refuses itself when the switch is off.
        if settings.localNetworkFirst, connection != nil, activeEndpoint?.isLocalNetwork != true {
            await scanForLocalNetwork()
        }
        // Twice, not once: a reconnect that was already in flight when the
        // switch moved can land on the route it forbids, and the second pass is
        // what closes that one too.
        for _ in 0..<2 {
            guard let host, let endpoint = activeEndpoint else { return }
            let allowed = RoutePolicy.allows(
                endpoint,
                localNetworkFirst: settings.localNetworkFirst,
                directConnection: settings.directConnection,
            )
            guard !allowed else { return }
            // Named by the switch that forbade it, because that is the sentence
            // an operator reads back in an export: "I turned that off, so why is
            // it still here" has to be answerable from one line.
            let switchName: String
            switch endpoint {
            case .direct: switchName = "local network first"
            case .p2p: switchName = "direct connection"
            case .relay: switchName = "relay"
            }
            log.add(
                .connection,
                "\(switchName) switched off: closing the \(Self.routeName(endpoint)) link now",
            )
            let remaining = RoutePolicy.allowed(
                host.endpoints,
                localNetworkFirst: settings.localNetworkFirst,
                directConnection: settings.directConnection,
            )
            guard !remaining.isEmpty else {
                // Nothing is left to redial: the switches now forbid every route
                // this pairing has. Drop the link (the operator asked for that)
                // and say why, rather than leaving a socket up that the settings
                // no longer allow or a screen that still calls it connected.
                eventListener?.cancel()
                interactionPoll?.cancel()
                await connection?.disconnect()
                connection = nil
                let message = String(
                    localized: "No route is allowed: the local network and the direct connection are both off, and this pairing has no relay address. Turn one back on to reconnect.",
                )
                connectionError = message
                // A switch, not a network: the phone is what refuses to dial,
                // so the cross sits on the phone's own side.
                let topology = LinkStatus.plannedTopology(for: host)
                linkFailure = LinkStatus(
                    topology: topology,
                    connected: false,
                    broken: topology == .relay ? .phoneToRelay : .phoneToComputer,
                    label: .computerUnreachable,
                )
                phase = .failed(message)
                return
            }
            // `reconnect` disconnects first, so the socket is gone before this
            // call returns, and its route list can only contain what remains.
            await reconnect(preferringRelay: true)
        }
    }

    /// The app came back from the background.
    ///
    /// iOS freezes the process, and a socket that was fine when the screen went
    /// away can be dead by the time it comes back -- on a phone that changed
    /// networks in a pocket it usually is. The app used to keep the dead object
    /// and say "Offline" until somebody found the Reconnect button, which is the
    /// reported bug: leave the app, come back, everything is offline.
    ///
    /// So returning is a redial, not a read on the old socket -- and the redial
    /// asks the local network first, because that is where the phone usually is.
    ///
    /// The order is the operator's: **scan the LAN, and only if nothing answers
    /// start the other routes**, with the punched route and the relay both held
    /// back by the same head start (see ``connect(using:preferring:)``). That is
    /// cheaper than the sequential redial this used to do: a dead LAN address
    /// no longer costs its whole leash before the relay is even started.
    ///
    /// The scan after the redial is not redundant. A pairing made while the
    /// computer listened only on loopback stores the relay address and nothing
    /// else; its LAN addresses exist only in the host's own answer, and the host
    /// can only be asked over a live socket. So the *second* scan runs once there
    /// is one, and a LAN address that changed while the app slept is found there.
    func refreshAfterReturning() async {
        beginAutomaticRefresh()
        defer { endAutomaticRefresh() }
        // 1. The operator is usually back on their own Wi-Fi. A hit here has
        //    already dialled the LAN address and switched the pairing to it.
        let onLocalNetwork = await scanForLocalNetwork()
        if !onLocalNetwork, let host {
            // 2. Nothing we know answered: replace whatever socket the return
            //    inherited and race the routes the switches allow.
            disconnectCurrent()
            let adopted = (try? await connect(using: host)) != nil
            if adopted {
                // 3. A socket exists now, so the host can be asked for the
                //    addresses it is listening on -- the one fact the pairing
                //    cannot know in advance.
                await scanForLocalNetwork()
            }
        }
        await refreshSessions(reconnectingIfNeeded: false)
        await refreshInteractions()
    }

    /// Mark an automatic pass as running, for the refresh button to draw.
    ///
    /// Paired with ``endAutomaticRefresh()`` on every path, including the
    /// cancelled ones: a counter left above zero would leave the button
    /// spinning and untappable until the app was relaunched.
    private func beginAutomaticRefresh() {
        automaticRefreshes += 1
    }

    /// Mark an automatic pass as finished.
    private func endAutomaticRefresh() {
        automaticRefreshes = max(0, automaticRefreshes - 1)
    }

    /// Try the operator's own network before the relay.
    ///
    /// Candidates are the direct address the pairing carries plus, when the
    /// host is reachable at all, every address its listener is bound to
    /// (`host.info`'s `addresses`, a plugin 0.8.5+ field). Each is probed over
    /// plain HTTP with the same unauthenticated `hello` the pairing screen uses,
    /// and the host id in the answer must match this pairing's: an address that
    /// answers as somebody else's computer is not this computer.
    ///
    /// The stored address is the one that may be stale -- it is a DHCP lease
    /// from whenever the phone was paired -- which is why the live socket is
    /// also asked what it is listening on now.
    ///
    /// - Returns: whether the scan dialled a local route and is now connected
    ///   over it.
    @discardableResult
    func scanForLocalNetwork() async -> Bool {
        // The transfer switch is the budget decision. With LAN priority off
        // there is no question to ask, and asking it would add a probe timeout
        // to every reconnect for an answer the operator said they would rather
        // not wait for. The one log line stays so the diagnosis can tell "the
        // operator turned it off" from "the scan ran and found nothing".
        guard settings.values.localNetworkFirst else {
            log.add(.connection, "LAN scan: skipped (local network priority is off)")
            return false
        }
        guard let host else { return false }
        if connection != nil, activeEndpoint?.isLocalNetwork == true {
            log.add(.connection, "LAN scan: already on the local network")
            return false
        }
        var candidates = host.endpoints.compactMap { endpoint -> String? in
            guard case .direct(let authority) = endpoint else { return nil }
            return authority
        }
        if let connection {
            // Best effort: an older host answers without `addresses`, and the
            // stored authority is still probed.
            if let info = try? await connection.call("host.info", as: HostInfo.self) {
                candidates.append(contentsOf: (info.addresses ?? []).filter { !$0.isEmpty })
            }
        }
        var seen: Set<String> = []
        let ordered = candidates.filter { !$0.isEmpty && seen.insert($0).inserted }
        guard !ordered.isEmpty else {
            log.add(.connection, "LAN scan: this pairing knows no direct address")
            return false
        }
        // Probed together rather than one after another. The addresses are
        // attempts at the same question, and on a phone that has walked out of
        // range none of them is coming: waiting for the first timeout before
        // starting the second would make a pull-to-refresh cost one timeout per
        // address. The earliest candidate that answered as this computer still
        // wins, so the order continues to decide between two working addresses.
        let hostId = host.hostId
        let probe = PairingClient(transport: URLSessionHTTPTransport(timeout: Self.lanProbeTimeout))
        var answered: Set<String> = []
        await withTaskGroup(of: (authority: String, matched: Bool).self) { group in
            for authority in ordered {
                group.addTask {
                    guard let answer = try? await probe.hello(authority: authority) else {
                        return (authority, false)
                    }
                    // An address that answers as somebody else's computer is
                    // not this computer, however plausible it looks.
                    return (authority, answer.hostId == hostId)
                }
            }
            for await result in group where result.matched {
                answered.insert(result.authority)
            }
        }
        log.add(.connection, "LAN scan: \(answered.count) of \(ordered.count) address(es) answered as this computer")
        guard let authority = ordered.first(where: answered.contains) else {
            log.add(.connection, "LAN scan: no local address answered")
            return false
        }
        if case .direct(let current) = activeEndpoint, current == authority {
            // The route already in use is this address and it answered: the
            // link is direct, but nothing moved. A foreground return still
            // wants its redial, so this is not a switch.
            return false
        }
        return await moveToLocalRoute(authority: authority)
    }

    /// Move the pairing to a direct address that has just answered.
    ///
    /// The credential is written first: if the dial below fails and the app is
    /// killed, the next launch must try the address that answered rather than
    /// the lease that expired. A dial that fails after a successful HTTP probe
    /// puts the previous route back -- a link that half works is not worth
    /// losing the working one for -- and the log says so.
    ///
    /// - Parameter authority: the `host:port` that answered as this computer.
    /// - Returns: whether the app is now connected over it.
    private func moveToLocalRoute(authority: String) async -> Bool {
        // The scan is the only caller and already refuses when the switch is
        // off; this is the same question asked where the dial happens, because
        // a future caller must not be able to route around the setting.
        guard settings.values.localNetworkFirst else {
            log.add(.connection, "LAN scan: not moving to \(authority); local network first is off")
            return false
        }
        guard let host else { return false }
        let previousEndpoint = activeEndpoint
        let moved = host.moved(to: authority)
        self.host = moved
        if let index = hosts.firstIndex(where: { $0.hostId == moved.hostId }) { hosts[index] = moved }
        try? await credentials.save(moved)
        activeEndpoint = .direct(authority: authority)
        log.add(.connection, "LAN scan: dialling \(authority)")
        // Exactly this address: a fallback that landed on the relay would be
        // reported as "switched to the local network" while the phone was on
        // the relay, and the stored credential would have been rewritten to an
        // address that does not actually work.
        if await reconnect(over: .direct(authority: authority)) {
            log.add(.connection, "LAN scan: switched to the local network at \(authority)")
            return true
        }
        log.add(.connection, "LAN scan: \(authority) answered the probe but not the socket; keeping the previous route")
        self.host = host
        if let index = hosts.firstIndex(where: { $0.hostId == host.hostId }) { hosts[index] = host }
        try? await credentials.save(host)
        activeEndpoint = previousEndpoint
        if let previousEndpoint { _ = await reconnect(over: previousEndpoint) }
        return false
    }

    /// How often the app asks whether its computer is on the local network.
    ///
    /// Slow on purpose. This is not a health check -- the socket already knows
    /// whether it is alive -- it is the one question a phone cannot be told the
    /// answer to: "am I back on my own Wi-Fi". Half a minute is fast enough to
    /// feel automatic when somebody walks back into the house, and slow enough
    /// that a phone out on cellular spends almost nothing on it.
    private static let lanWatchInterval: Duration = .seconds(30)

    /// Start or stop the resident LAN watch from whether the app is on screen.
    ///
    /// The task sleeps first, so a return to the foreground does not scan twice:
    /// ``refreshAfterReturning()`` has just asked the same question. iOS freezes
    /// the process in the background, so there is nothing to keep running there.
    private func updateLanWatch() {
        guard appIsActive else {
            guard lanWatch != nil else { return }
            lanWatch?.cancel()
            lanWatch = nil
            return
        }
        guard settings.values.localNetworkFirst else {
            // Off means no probing at all, not a task that wakes every half
            // minute to decide not to. The watch exists only to notice a
            // computer that came back onto the network; with the route
            // forbidden there is nothing for it to notice.
            lanWatch?.cancel()
            lanWatch = nil
            return
        }
        guard lanWatch == nil else { return }
        log.add(.connection, "LAN watch: started, one probe every \(Self.lanWatchInterval)")
        lanWatch = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: Self.lanWatchInterval)
                } catch {
                    // Cancellation is the stop path; there is nothing to report.
                    return
                }
                guard !Task.isCancelled, let self else { return }
                await self.lanWatchTick()
            }
        }
    }

    /// Ask the local network, on a slow clock, whether the computer is on it.
    ///
    /// The relay is the route that works from anywhere, which is exactly why a
    /// phone ends up on it and stays there: a reconnect dials whichever route
    /// worked last, and carrying the phone back into its own Wi-Fi does not
    /// change that by itself. So the app asks on a timer, and moves the pairing
    /// to the direct address the moment one answers -- which is also the moment
    /// the relay stops metering this phone's traffic.
    ///
    /// Silent by design: a scan that finds nothing changes nothing on screen and
    /// says nothing to the operator; its own log lines are the record. Nothing
    /// is asked when the answer is already known -- a direct link in use, no
    /// socket to be on the relay in the first place, or a reconnect already
    /// choosing a route -- and nothing is asked when the operator has turned
    /// local-network priority off, because that switch is their answer to this
    /// exact question.
    private func lanWatchTick() async {
        guard appIsActive, host != nil else { return }
        guard settings.values.localNetworkFirst else { return }
        guard connection != nil, !reconnecting else { return }
        guard activeEndpoint?.isLocalNetwork != true else { return }
        await scanForLocalNetwork()
    }

    /// Refresh the session list, reconnecting first when the socket is gone.
    ///
    /// Every assignment below is behind the subject the read was started for.
    /// `call` can reconnect -- which replaces the socket and can land on a
    /// different pairing entirely -- and a list read for one computer assigned after
    /// that draws that computer's sessions under another one's name. The list is the
    /// machine's, and so is the workspace set written with it.
    ///
    /// - Parameter reconnectingIfNeeded: whether a failure should be retried
    ///   over a fresh connection. The background refresh says no: a reconnect
    ///   can take the whole of the assertion, and a list read that fails
    ///   off screen is a list read for the next foreground.
    ///
    /// A refresh with no socket at all -- the computer was unreachable long enough
    /// for the connection to be torn down -- opens one before it reads. That is
    /// the recovery the list's old yellow Retry button performed by hand, and
    /// with that button gone it has to live in the refresh the operator already
    /// has: pull to refresh, and the toolbar's refresh, both land here.
    func refreshSessions(reconnectingIfNeeded: Bool) async {
        if connection == nil {
            guard reconnectingIfNeeded, await reconnect() else { return }
        }
        guard connection != nil, let tag = currentTag else { return }
        do {
            let result = try await call("session.list", as: SessionListResult.self)
            guard tag == currentTag else {
                log.add(.cache, "session list for \(tag.hostId) dropped, the machine changed under it")
                return
            }
            sessions = Self.scoped(result.items, to: engineScope)
            sessionsAreKnown = true
            await refreshWorkspaces()
            lastError = nil
            // Written after the workspaces, so the two halves of one answer land
            // together rather than as a list with the previous workspace set.
            await persistIndex()
            // Which sessions are running is half of what the island shows, and
            // this is the read that knows.
            await refreshLiveActivity()
        } catch {
            if reconnectingIfNeeded, await reconnect() {
                await refreshSessions(reconnectingIfNeeded: false)
                return
            }
            // Reported, not fatal. The pairing is still good and most of the
            // screen is still usable; throwing the operator out to a failure
            // screen over one dropped request is a worse answer than saying so.
            // Only if this is still the machine it was asked about: a failed read
            // for a computer the operator has left is not this screen's problem.
            guard tag == currentTag else { return }
            lastError = Self.describe(error).isEmpty ? nil : Self.describe(error)
        }
    }

    /// Re-read which workspaces DSH has.
    ///
    /// Best effort, and deliberately silent on failure. The session list can be
    /// drawn without this, so a host that does not answer leaves the previous
    /// answer in place rather than emptying the screen.
    ///
    /// What is *not* best effort is acting on the answer. `complete` is the
    /// host saying "this is all of them", and only then may a workspace that is
    /// absent be dropped — including when the list comes back empty, which is
    /// what "the operator deleted their last workspace" looks like. Treating an
    /// empty answer as no answer is precisely how deleted workspaces stayed on
    /// this screen: the phone kept the old list and drew it forever.
    private func refreshWorkspaces() async {
        // `connection.call`, not `call`: the shared helper reconnects the whole
        // socket when a request fails, and this is a best-effort read of a
        // method an older host does not implement. Going through it meant one
        // unimplemented method tore down the connection every time the session
        // list refreshed -- which the context figure above the composer noticed
        // before anything else did.
        guard let connection, let tag = currentTag else { return }
        do {
            let result = try await loggedCall("workspace.list", on: connection, as: WorkspaceListResult.self)
            guard result.complete else { return }
            // The stored list is *this* computer's registry: "the host has no such
            // workspace" is only an answer about the host that said it.
            guard tag == currentTag else { return }
            workspaces = Self.scoped(result.items, to: engineScope)
        } catch {
            // Left alone on purpose. See above.
        }
    }

    /// Run one call, reconnecting once if the socket has gone away.
    ///
    /// - Parameters:
    ///   - method: the method name.
    ///   - type: the result type.
    /// - Returns: the decoded result.
    /// - Throws: when the call fails twice.
    /// Run one call, reconnecting once if the socket has gone away.
    ///
    /// - Parameters:
    ///   - method: the method name.
    ///   - payload: the arguments, when the method takes any.
    ///   - type: the result type.
    /// - Returns: the decoded result.
    /// - Throws: when the call fails twice.
    private func call<T: Decodable & Sendable>(
        _ method: String,
        payload: JSONValue? = nil,
        as type: T.Type,
    ) async throws -> T {
        guard let connection else {
            let failure = MizarError(code: "NO_CONNECTION", message: "not connected to the computer")
            logRequest(method, payload: payload, since: .now, error: failure)
            throw failure
        }
        let started = ContinuousClock.now
        do {
            let result = try await connection.call(method, payload: payload, as: type)
            logRequest(method, payload: payload, since: started, error: nil)
            return result
        } catch {
            guard Self.isAboutTheConnection(error) else {
                logRequest(method, payload: payload, since: started, error: error)
                throw error
            }
            guard await reconnect() else {
                logRequest(method, payload: payload, since: started, error: error)
                throw error
            }
            guard let fresh = self.connection else { throw error }
            do {
                let result = try await fresh.call(method, payload: payload, as: type)
                logRequest(method, payload: payload, since: started, error: nil)
                return result
            } catch {
                logRequest(method, payload: payload, since: started, error: error)
                throw error
            }
        }
    }

    /// Whether a failure is one a fresh socket could fix.
    ///
    /// The distinction this draws is between a socket that is not working and an
    /// *answer* the host chose to send over one that is. Every failure used to
    /// reconnect, so a `NOT_IMPLEMENTED` from an older host tore the connection
    /// down on every session-list refresh -- which the context figure noticed
    /// first, and which is why `refreshWorkspaces` was taken off this path by
    /// hand -- and a `WRITER_HELD` or a `RESPONSE_TOO_LARGE` did the same to a
    /// request whose answer would be identical over a brand-new socket. A
    /// reconnect is a WebSocket, a handshake and a re-subscription: real seconds
    /// on a phone, spent on nothing.
    ///
    /// A cancelled read is the other half. The screen that asked has gone away,
    /// and the app used to answer that by rebuilding the connection underneath
    /// whatever was still on screen.
    ///
    /// - Parameter error: what the call threw.
    /// - Returns: whether to reconnect and try the request again.
    private static func isAboutTheConnection(_ error: any Error) -> Bool {
        if error is CancellationError { return false }
        if let urlError = error as? URLError, urlError.code == .cancelled { return false }
        guard let mizar = error as? MizarError else {
            // A transport failure or a decode failure: something about this
            // socket or this frame, and worth one fresh attempt.
            return true
        }
        // The host saying "this one might work in a moment".
        if mizar.retryable { return true }
        switch mizar.known {
        // Codes that say the socket itself is finished with this device.
        case .unauthenticated, .deviceRevoked, .pairingRequired,
             .malformedFrame, .protocolVersionMismatch:
            return true
        default:
            return false
        }
    }

    /// Run one call on a connection the caller already holds, logging it.
    ///
    /// The counterpart of ``call(_:payload:as:)`` for the requests that are
    /// deliberately not retried -- presence, the catalogues, the interaction
    /// reads, the registration with the relay. Each of those has its own answer
    /// for a failure, and a reconnect underneath them would be a second attempt
    /// nobody asked for, over a link the caller is about to report on.
    ///
    /// - Parameters:
    ///   - method: the wire method.
    ///   - payload: the arguments, when there are any.
    ///   - connection: the connection to use.
    ///   - type: the result type.
    /// - Returns: the decoded result.
    /// - Throws: whatever the call threw.
    @discardableResult
    private func loggedCall<T: Decodable & Sendable>(
        _ method: String,
        payload: JSONValue? = nil,
        on connection: MizarConnection,
        as type: T.Type,
    ) async throws -> T {
        let started = ContinuousClock.now
        do {
            let result = try await connection.call(method, payload: payload, as: type)
            logRequest(method, payload: payload, since: started, error: nil)
            return result
        } catch {
            logRequest(method, payload: payload, since: started, error: error)
            throw error
        }
    }

    /// Write one host call into the activity log.
    ///
    /// The method, the *names* of its arguments, how long it took and how it
    /// ended. Never the values: prompts, answers, prompts' session text and the
    /// device token all travel in payloads, and a diagnostic archive that quoted
    /// them would be a transcript of somebody's work rather than a record of a
    /// connection. The names are what makes a failure diagnosable -- that a
    /// request carried a `beforeSeq` and no `maxMessages` is the whole answer to
    /// some questions.
    ///
    /// - Parameters:
    ///   - method: the wire method.
    ///   - payload: the arguments, when there were any.
    ///   - started: when the call began.
    ///   - error: what went wrong, or `nil` when it worked.
    private func logRequest(
        _ method: String,
        payload: JSONValue?,
        since started: ContinuousClock.Instant,
        error: (any Error)?,
    ) {
        let taken = ContinuousClock.now - started
        var arguments: [String] = []
        if case .object(let fields) = payload { arguments = Array(fields.keys) }
        let detail = RequestDetail(
            method: method,
            arguments: arguments,
            durationMs: taken / .milliseconds(1),
            outcome: error == nil ? .ok : .failed,
            errorCode: (error as? MizarError)?.code,
            errorMessage: error.flatMap { Self.describe($0).isEmpty ? nil : Self.describe($0) },
        )
        log.add(.request, detail.summary, request: detail)
    }

    /// Open a fresh connection to the current machine.
    ///
    /// The app had no way back from a dropped socket: `URLSessionWebSocketTask`
    /// does not reconnect, and every screen simply failed until the app was
    /// restarted. A phone changes networks constantly -- walking out of Wi-Fi
    /// range is enough -- so this is the common case, not an edge one.
    ///
    /// Two callers want different things from it. A call that has just failed
    /// wants one quick retry before it reports, so those paths get three fast
    /// attempts. The failure screen's button is a person asking again, and there
    /// the only honest answer is to keep trying while their network comes back:
    /// three attempts inside a second is a formality, not a retry. The device log
    /// from the phone that prompted this reads `-1009`, "not connected to the
    /// internet" -- no number of sub-second retries outlasts that.
    ///
    /// The route that was working comes first and the rest of the pairing
    /// follows it: a dropped request is asking to rebuild that socket, and a
    /// route that has actually gone away must fall through to the other one
    /// *inside this reconnect* rather than being retried until the next read.
    /// That fall-through is the fix for the reported bug -- a phone connected
    /// over the LAN kept dialling the lost local address while the relay in the
    /// same pairing was never tried.
    ///
    /// - Parameters:
    ///   - patient: whether to keep trying long enough to outlast a
    ///     phone that has lost its network.
    ///   - tryingEveryRoute: whether to start from the pairing's own order
    ///     instead of the route that worked last. A foreground return uses
    ///     this: the network may have changed while the app slept.
    ///   - preferringRelay: whether to put the relay in front. A local link
    ///     that has just died uses this -- the one thing that failure says is
    ///     that the network carrying it is gone.
    ///   - exactRoute: dial exactly this route, no fallback. A LAN scan that is
    ///     moving the pairing to a new address needs to know whether *that*
    ///     address works, not whether some other route does.
    /// - Returns: whether a connection is now open.
    @discardableResult
    func reconnect(
        patient: Bool = false,
        tryingEveryRoute: Bool = false,
        preferringRelay: Bool = false,
        over exactRoute: PairedHost.Endpoint? = nil,
    ) async -> Bool {
        guard let host else { return connection != nil }
        if reconnecting {
            // Someone else is already bringing the socket back; wait for them.
            //
            // This used to `return connection != nil`, which reports "still
            // down" rather than "wait" -- because the attempt already in flight
            // clears `connection` at its top, so during the whole of a reconnect
            // every concurrent caller was told there was no connection and threw.
            //
            // Two reads run together on the session screen, usage and the
            // conversation, and they share one socket: one dropped request made
            // them fail as a pair. That is the reported symptom exactly -- the
            // Usage tab empty and the message list sitting at a strange offset,
            // together, and only sometimes.
            // Wait for the attempt in flight -- but never on itself, and never
            // without end.
            //
            // This loop deadlocked the whole app. `reconnect` used to refresh
            // the session list before releasing the flag, and that refresh can
            // itself fail and call `reconnect`: the inner call arrived while the
            // flag was still held, waited here for the outer one to finish, and
            // the outer one was blocked waiting for the inner. Neither ever
            // returned, `reconnecting` stayed true for the life of the process,
            // and from then on every failed request waited here forever -- which
            // is why every conversation sat on a spinner while the connection
            // underneath was healthy and answering. The refresh no longer
            // happens inside the lock; the deadline and the cancellation check
            // are so that a future mistake of the same shape stalls a request
            // instead of the app.
            let deadline = ContinuousClock.now.advanced(by: .seconds(20))
            while reconnecting, ContinuousClock.now < deadline {
                do {
                    try await Task.sleep(for: .milliseconds(50))
                } catch {
                    break
                }
            }
            return connection != nil
        }
        reconnecting = true
        defer { reconnecting = false }
        log.add(
            .connection,
            "reconnecting\(patient ? " (patient)" : "")\(tryingEveryRoute ? " (every route)" : "")",
        )

        eventListener?.cancel()
        interactionPoll?.cancel()
        await connection?.disconnect()
        connection = nil

        // Which routes to dial, in order, and how many attempts they get. Both
        // decisions live in `ReconnectPlan` so they are tested without a socket:
        // the last working route first, every other route behind it, and -- when
        // a local link has just died -- the relay first, because the network the
        // local address lives on is the thing that broke.
        // One question, asked of every route: do the switches allow it. An
        // exact route is not an exception -- a LAN scan that is moving the
        // pairing, and a pairing that has just completed over the LAN, both
        // arrive here with a route that the operator may have switched off.
        let allowed = { (endpoint: PairedHost.Endpoint) in
            RoutePolicy.allows(
                endpoint,
                localNetworkFirst: self.settings.localNetworkFirst,
                directConnection: self.settings.directConnection,
            )
        }
        let routes: [PairedHost.Endpoint]
        if let exactRoute, allowed(exactRoute) {
            routes = [exactRoute]
        } else {
            routes = ReconnectPlan.routes(
                endpoints: host.endpoints,
                active: activeEndpoint,
                tryingEveryRoute: tryingEveryRoute,
                preferringRelay: preferringRelay,
                // The two switches, in one place: the direct route is planned
                // only while 局域网优先 is on, and the punched route only while
                // 直连 is.
                allowingLocalNetwork: settings.localNetworkFirst,
                allowingDirectPath: settings.directConnection,
            )
        }
        guard !routes.isEmpty else {
            log.add(
                .connection,
                "reconnect: no route the switches allow "
                    + "(local network first \(settings.localNetworkFirst ? "on" : "off"), "
                    + "direct connection \(settings.directConnection ? "on" : "off"))",
            )
            return false
        }
        let attempts = ReconnectPlan.attempts(routeCount: routes.count, patient: patient)
        log.add(
            .connection,
            "routes: " + routes.map(Self.routeName).joined(separator: " -> "),
        )
        // The failure worth showing, kept across attempts. See the catch below.
        var shown: RouteFailure?
        for attempt in 0..<attempts {
            if attempt > 0 {
                let pause = patient ? min(4_000, 400 << attempt) : 400 * attempt
                try? await Task.sleep(for: .milliseconds(pause))
            }
            let route = routes[attempt % routes.count]
            let next = makeConnection(host: host, endpoint: route)
            do {
                _ = try await next.connect()
                connection = next
                // The route that actually answered is the route the app is on:
                // a scan or a foreground return may have chosen a different one
                // from the last, and the footer, the entitlement and the next
                // reconnect all read this.
                activeEndpoint = route
                // The alternate relay may be the one that answered while the
                // stored URL was stale; keep the pairing in step with reality.
                if case .relay(let baseURL) = route, self.host?.baseURL != baseURL {
                    await rememberRelayBaseURL(baseURL)
                }
                // A reconnect is a new conversation with the same machine, and
                // the epoch says so. Everything scoped to the old socket -- the
                // catalogues, the pending set, an answer still on its way --
                // was answered by a host this app is no longer talking to, and
                // a host id alone cannot tell that apart from the same machine
                // still answering. Without this, a read started before the drop
                // and delivered after the new socket opened passed every tag
                // check and was published as current.
                nextConnectionEpoch += 1
                connectionEpoch = nextConnectionEpoch
                lastError = nil
                connectionError = nil
                linkFailure = nil
                log.add(.connection, "reconnected after \(attempt + 1) attempt(s)")
                startInteractionPoll()
                // `phase` decides which screen is on. This never touched it, so
                // a retry that *succeeded* left the operator looking at "Cannot
                // reach the computer" with a working connection behind it -- the
                // button did its job and the screen never said so. That was the
                // bug: "Try again does nothing" was true on the only screen
                // where it could be seen.
                phase = .ready
                // The account's tier is the phone's fact, not the host's. A
                // reconnect is the first moment after an offline plan change
                // that this side can align the tunnel's relay.
                await syncRelayTier()
                // The session list is *not* refreshed here. It used to be, and
                // that call is what closed the deadlock above; every caller
                // either refreshes for itself or is about to.
                return true
            } catch {
                let failed = RouteFailure(
                    isRelay: ReconnectPlan.isRelay(route),
                    address: Self.routeDescription(route).address,
                    error: error,
                )
                let message = Self.describe(failed)
                log.add(
                    .connection,
                    "reconnect attempt \(attempt + 1)/\(attempts) over \(Self.routeName(route)) failed: \(message)",
                )
                // The most informative failure so far, not the latest. With two
                // routes the last one is usually the direct address timing out
                // six seconds after the relay already answered, and the relay's
                // answer is the one that explains the screen.
                if shown == nil || Self.weight(failed) >= Self.weight(shown!) { shown = failed }
                let reported = shown.map { Self.describe($0) } ?? message
                connectionError = reported.isEmpty ? nil : reported
                lastError = reported.isEmpty ? nil : reported
                // The bar ranks the same way the sentence does: the most
                // informative attempt decides which segment carries the cross.
                linkFailure = shown.map {
                    LinkStatus.failure($0.error, authority: $0.address, isRelay: $0.isRelay)
                }
                // Keep the screen's text current. A retry that fails for a new
                // reason -- no internet rather than the computer being unreachable --
                // should say so instead of repeating the line from before.
                if case .failed = phase, !reported.isEmpty { phase = .failed(reported) }
            }
        }
        log.add(.connection, "reconnect gave up after \(attempts) attempts")
        return false
    }

    /// Fetch the page before the oldest one held, and fold it in.
    ///
    /// What scrolling to the top of a conversation asks for. The host pages by
    /// `beforeSeq`, so the position to ask for is the oldest log entry the phone
    /// already has -- and when it has none, there is nothing to page from.
    ///
    /// - Parameter sessionId: the session to extend.
    /// - Returns: how many new items arrived, `0` when the host was asked and
    ///   has nothing older, or `nil` when the question could not be asked at
    ///   all. The caller must not treat `nil` as the end of the conversation:
    ///   every early exit here is a condition that can clear on its own.
    @discardableResult
    func loadOlder(sessionId: String) async -> Int? {
        guard connection != nil else { return nil }
        guard let cached = await conversations.load(sessionId: sessionId),
              let before = cached.oldestSeq
        else { return nil }
        // Nothing older to ask for. Without this the scroll-to-top would fire a
        // request on every appearance for a page that cannot change. This one is
        // definitive: the host said so, not a transient failure of ours.
        guard cached.hasMore else { return 0 }

        do {
            let result = try await messages(
                sessionId: sessionId,
                beforeSeq: before,
            )
            let fresh = result.conversationItems()
            let reached = result.oldestSeq
            // The host answers with the tail before `beforeSeq`, so the same
            // page coming back means there is nothing further; stopping is what
            // keeps a scroll at the top from looping.
            if reached == nil || reached == before || fresh.isEmpty { return 0 }

            // Folded in as one step, so a reload landing at the same moment
            // cannot have its write undone by this one.
            let stored = await conversations.update(sessionId: sessionId) { current in
                // `current` rather than the `cached` read before the request:
                // that one is several round trips old by now, and anything the
                // time it took fetched would be thrown away.
                Self.folding(older: result, into: current ?? cached, sessionId: sessionId)
            }
            lastError = nil
            log.add(
                .cache,
                "session \(sessionId): paged back, \(stored.items.count) items now held",
            )
            return stored.items.count - cached.items.count
        } catch {
            let message = Self.describe(error, authority: host?.authority ?? host?.baseURL)
            if !message.isEmpty { lastError = message }
            return nil
        }
    }

    /// Fold a page fetched with `beforeSeq` into a stored conversation.
    ///
    /// Backwards pages are read by two callers that must agree on what they
    /// mean: the operator scrolling up (``loadOlder(sessionId:)``) and the
    /// repair that fills a window a forward read stepped over
    /// (``repairStaleRunningTurns(for:)``). They differ only in where the page
    /// starts, so the fold is one rule with one home.
    ///
    /// The delivery cursor is **carried forward untouched**: older records
    /// cannot raise the highest position this phone has been given, and moving
    /// it would make the next forward read skip whatever lies between. The
    /// page's cut and `hasMore` describe the older end, which is this page's
    /// whole subject.
    ///
    /// - Parameters:
    ///   - page: one page the host returned for `beforeSeq`.
    ///   - known: what the phone holds for the session.
    ///   - sessionId: the session the page belongs to.
    /// - Returns: the conversation with the page folded in.
    private nonisolated static func folding(
        older page: SessionMessagesResult,
        into known: CachedConversation,
        sessionId: String,
    ) -> CachedConversation {
        CachedConversation(
            sessionId: sessionId,
            items: mergeConversations(cached: known.items, fresh: page.conversationItems()),
            throughSeq: known.throughSeq,
            hasMore: page.hasMore,
            turns: mergeTurns(cached: known.turns ?? [], fresh: page.conversationTurns()),
            oldestSeq: [known.oldestSeq, page.oldestSeq].compactMap { $0 }.min(),
            stats: statsFrame(carrying: page.context, over: known.stats),
            deliveredSeq: known.deliveredSeq,
        )
    }

    /// The stored usage frame with a page's context figure folded in.
    ///
    /// The page carries the context window and its breakdown on every refresh,
    /// full and incremental alike (see ``SessionMessagesResult/context``), and
    /// the composer reads the figure from the cached frame -- so the page's
    /// figure has to land there or it is thrown away with the reply.
    ///
    /// The rest of the frame is the previous one, field for field: a page says
    /// nothing about token usage, title or model, and replacing it with a frame
    /// that only carries `context` would blank the figures the screen already
    /// had. A page without a figure (an older plugin) leaves the frame alone:
    /// absent is unknown, not zero.
    ///
    /// - Parameters:
    ///   - context: the context figure the page carried, when it carried one.
    ///   - previous: the frame the cache already held.
    /// - Returns: the frame to store, or `nil` when there is nothing to store.
    private nonisolated static func statsFrame(
        carrying context: ContextPressure?,
        over previous: SessionStatsFrame?,
    ) -> SessionStatsFrame? {
        guard let context else { return previous }
        return SessionStatsFrame(context: context).merging(previous)
    }

    /// Read a session's conversation from the phone's own storage.
    ///
    /// - Parameter sessionId: the session.
    /// - Returns: the cached conversation, or `nil` when none is stored.
    func cachedConversation(for sessionId: String) async -> CachedConversation? {
        await conversations.load(sessionId: sessionId)
    }

    /// Sync every session's history to this phone.
    ///
    /// Run on first pairing and from the refresh button. Paging rather than
    /// asking for everything at once: a page that does not arrive costs the
    /// freshness of one screen, which is the lesson the two-megabyte page
    /// taught.
    func syncAllConversations() async {
        // One at a time, and the flag is released on every exit.
        //
        // This has no other guard: the button that starts it is disabled while
        // `isSyncing`, but `syncProgress` was only set after the session list
        // came back, so a second tap in that window started a second full pass
        // over every session. Measured on a real run, seven passes' worth of
        // pages were fetched for one refresh -- about five megabytes each, over
        // a relay, on a phone.
        //
        // The `defer` matters more than the guard. `syncProgress` was assigned
        // nil at the end of the happy path only, so any early return or
        // cancellation left `isSyncing` true for good, with the refresh button
        // spinning and disabled and no way back.
        guard syncProgress == nil else {
            log.add(.sync, "history sync: already running, second request ignored")
            return
        }
        syncProblem = nil
        // One clock for the whole pass, carried across the two assignments
        // below: the estimate is measured from when the operator asked, not from
        // whenever the session list happened to come back.
        let startedAt = Date()
        log.add(.sync, "history sync: starting")
        syncProgress = SyncProgress(current: "", completed: 0, total: sessions.count, startedAt: startedAt)
        defer { syncProgress = nil }

        // The refresh opens a socket when there is none -- that is where the
        // old Retry button's reconnect now lives -- so the connection is
        // checked after it rather than before it. The LAN question comes first
        // for the same reason a plain refresh asks it: this is a manual update,
        // and a manual update is the operator saying "get current", which
        // includes being on the right network.
        await scanForLocalNetwork()
        await refreshSessions()
        guard connection != nil else {
            log.add(.sync, "history sync: skipped, not connected to the computer")
            // Reported rather than silently skipped. The window is already up
            // by the time this runs, and doing nothing looks exactly like having
            // nothing to do.
            // The connection's own reason first: a pass that never started is
            // explained by why there is no socket, not by the read that noticed.
            syncProblem = connectionError ?? lastError ?? "Not connected to the computer."
            return
        }
        guard !sessions.isEmpty else {
            log.add(.sync, "history sync: the computer listed no sessions, or the list could not be read")
            // Either the computer listed nothing or the read failed. Both are worth
            // saying out loud; neither is "up to date".
            syncProblem = connectionError ?? lastError ?? "The computer listed no sessions."
            return
        }

        // Every top-level conversation, and only those. A forked conversation
        // ("branch in a new conversation") is a top-level one and its history
        // belongs on the phone; only a delegated child has no page the operator
        // would ever open here, and `isSubagent` is the host's own mark for it.
        let runnable = sessions.filter { !$0.isSubagent }
        log.add(.sync, "history sync: \(runnable.count) sessions to fetch")
        syncProgress = SyncProgress(current: "", completed: 0, total: runnable.count, startedAt: startedAt)

        for (index, session) in runnable.enumerated() {
            syncProgress?.current = session.cwd.map { ($0 as NSString).lastPathComponent } ?? session.sessionId
            await syncConversation(for: session.sessionId)
            // The usage frame too, not only the messages. It carries the row's
            // title and the model and context figures above the composer, and a
            // history download that skipped it left every row unnamed and every
            // session's cost unknown until the operator opened it -- on a link
            // that may not answer by then. One extra request per session, once.
            if let frame = await stats(for: session.sessionId),
               let title = frame.title, !title.isEmpty {
                titles[session.sessionId] = title
            }
            syncProgress?.completed = index + 1
            log.add(.sync, "history sync: \(index + 1)/\(runnable.count) \(session.sessionId)")
        }
        let elapsed = Date().timeIntervalSince(startedAt)
        log.add(.sync, String(format: "history sync: finished in %.1f s", elapsed))
        await persistIndex()
        // A pass over every session can see a session stop running without that
        // session being the one whose page was just fetched, which is the one
        // case the per-page refresh above cannot notice.
        await refreshLiveActivity()
        // The pass ran to the end. Whatever went wrong inside it is already
        // recorded, and this is the line that lets the window stop saying it.
        syncProblem = connectionError ?? lastError
    }

    /// One forward page read, and the usage frame it left in the cache.
    ///
    /// The screen reads the context figure from its `stats` state, and the page
    /// is what carries the fresh one -- so the read hands both halves back in
    /// one answer rather than making the caller re-read the cache it just
    /// wrote.
    struct SyncedConversation {
        /// The items now known, oldest first.
        let items: [ConversationItem]
        /// The cached usage frame after the page's context figure was folded
        /// in, or `nil` when nothing is known yet.
        let stats: SessionStatsFrame?
    }

    /// Fetch one session's page and fold it into the cache.
    ///
    /// - Parameter sessionId: the session to sync.
    /// - Returns: the items now known and the usage frame the cache holds after
    ///   the page's context figure was folded in.
    @discardableResult
    func syncConversation(for sessionId: String) async -> SyncedConversation {
        // What this phone holds decides what the host sends. A refresh used to
        // download the whole tail every time -- the phone already had every
        // record and paid for them again on every pull, reconnect and poll.
        let known = await conversations.load(sessionId: sessionId)
        let cursor: SessionMessagesCursor
        if let held = known?.deliveredSeq {
            cursor = .after(held)
        } else if known == nil {
            // Nothing stored at all. Said explicitly rather than left to the
            // host's memory: a reinstall keeps the device token -- the Keychain
            // survives the app -- but not the cache, and the host would then
            // answer a phone with nothing with only what it sent after the
            // reinstall.
            cursor = .empty
        } else {
            // A cache written before positions were stored: it holds records but
            // cannot say through where. Neither claim is true, so make neither.
            cursor = .unstated
        }
        do {
            let result = try await messages(sessionId: sessionId, afterSeq: cursor)
            let fresh = result.conversationItems()
            let freshTurns = result.conversationTurns()
            let older = result.oldestSeq
            // Read, merged and written as one step. Loading here and saving
            // three lines later is two, and the automatic paging at the top of
            // this conversation runs against a returning-to-foreground reload --
            // two overlapping read-modify-writes of one file lose one of them,
            // and what is lost is a page somebody just asked for.
            let stored = await conversations.update(sessionId: sessionId) { cached in
                CachedConversation(
                    sessionId: sessionId,
                    items: mergeConversations(cached: cached?.items ?? [], fresh: fresh),
                    throughSeq: result.asOfSeq,
                    hasMore: result.hasMore,
                    // Grouped on the fresh page and kept beside it, because a
                    // page is where the turn boundaries are -- they are in the
                    // records, and the merged item list has already lost which
                    // step belonged to what.
                    turns: mergeTurns(cached: cached?.turns ?? [], fresh: freshTurns),
                    // The older of the two: this page may not reach as far back as
                    // what is already stored, and paging from the wrong end would
                    // re-fetch what is already here.
                    oldestSeq: [cached?.oldestSeq, older].compactMap { $0 }.min(),
                    // The page's context figure, folded into the frame the
                    // composer draws from: every refresh carries one, so the
                    // occupancy ring moves with the turn instead of waiting for
                    // the next full load. A page without one leaves the frame
                    // alone -- see `statsFrame(carrying:over:)`.
                    stats: Self.statsFrame(carrying: result.context, over: cached?.stats),
                    // Advanced, never replaced: the page starts at a position
                    // newer than what is stored, and the highest position this
                    // phone has seen is the only thing it may claim next time.
                    deliveredSeq: [cached?.deliveredSeq, result.newestDeliveredSeq]
                        .compactMap { $0 }
                        .max(),
                )
            }
            lastError = nil
            conversationError = nil
            log.add(.cache, "session \(sessionId): stored \(stored.items.count) items")
            // A page can begin after records this phone never received -- the
            // host trims a page to its newest few hundred messages -- and a
            // `turn/end` among the skipped ones leaves a turn the screen draws
            // as still running above turns that finished. See
            // ``repairStaleRunningTurns(for:)``.
            let repaired = await repairStaleRunningTurns(for: sessionId)
            // The other half of what the island shows just arrived: the running
            // turn's own clock and the instruction it is working on. Refreshed
            // here rather than at the end of a full pass so that the first page
            // fetched -- normally the session the operator opened -- is enough to
            // put a real figure on the card instead of a clock started at zero.
            await refreshLiveActivity()
            // A repair folded older records in, and the screen draws the cache:
            // return what is on disk now rather than the page before the repair,
            // so "what is on screen and what is stored" stay the same answer.
            let known = repaired ? await conversations.load(sessionId: sessionId) : nil
            return SyncedConversation(
                items: known?.items ?? stored.items,
                stats: known?.stats ?? stored.stats,
            )
        } catch {
            // A cancelled read is not a failure to report. It is a phone being
            // suspended -- or, now, a background sync that ran out of its
            // assertion -- and the screen it would draw the error on is not on
            // screen. Left in, the operator coming back would find "The computer did
            // not answer" waiting for a computer that answered perfectly well the
            // moment the app could ask again.
            if Task.isCancelled {
                log.add(.cache, "session \(sessionId): read cancelled; nothing changed")
                return SyncedConversation(items: [], stats: nil)
            }
            let message = Self.describe(error, authority: host?.authority ?? host?.baseURL)
            if !message.isEmpty { lastError = message }
            // A read that fails with no message -- `describe` filters the ones
            // that are not the operator's fault -- would fall through to "this
            // session has no messages", which is a claim about their session
            // made from the absence of an answer. Cancellation is handled above;
            // this is every other silent failure.
            conversationError = message.isEmpty
                ? "The computer did not answer. Pull down to try again."
                : message
            return SyncedConversation(
                items: await conversations.load(sessionId: sessionId)?.items ?? [],
                stats: nil,
            )
        }
    }

    /// How many backward pages one repair will read for one missing end.
    ///
    /// A page holds the newest few hundred raw messages before the position it
    /// was asked for, so one page covers a page-window's worth of gap and four
    /// covers a phone that was away for several turns. The bound matters
    /// because this runs inside a refresh: a repair that walked a whole history
    /// back, over a relay, would be a refresh that never returns.
    private static let staleRunRepairPages = 4

    /// How many stale runs one refresh will try to repair.
    ///
    /// The shape is impossible for the agent, so in practice it is zero or one.
    /// More than a couple means something other than a skipped window is wrong
    /// with this phone's history; the rest are settled rather than repaired.
    private static let staleRunRepairRounds = 2

    /// Fetch the records an incremental page stepped over, when the merge proves
    /// one of them held a `turn/end`.
    ///
    /// The report this answers: "后面的对话都成功执行完毕结束了，前面还有会话显示
    /// 正在执行" -- every later turn finished, and a row above them still counted
    /// "深度求索中". The agent ends a turn before starting the next, so the
    /// agent's own log cannot show that; a copy of it can, when it is missing the
    /// `turn/end` that ended the turn. This phone's copy is the one that loses
    /// records, because its reads are incremental: a page is a window over the
    /// log, trimmed to its newest few hundred messages, and the phone asks only
    /// for records after the position it holds. When a whole window of activity
    /// happens between two reads -- a long turn, or a phone away long enough for
    /// several turns to pass -- the page begins after records that were never
    /// delivered, and the highest position it then claims steps over them **for
    /// good**: no later read asks for them again. A `turn/end` inside the skipped
    /// range is how that becomes a row that never stops counting, while the turns
    /// after it arrived finished.
    ///
    /// The repair is the read the operator's scroll-up already uses: a page of
    /// older records, asked for by `beforeSeq`. It starts at the earliest
    /// position of the first turn after the stale one -- the exclusive upper
    /// bound of the range the missing end can be in -- and walks back until the
    /// end arrives, the range is exhausted, or ``staleRunRepairPages`` is
    /// reached. What it folds in is kept: those records were conversation the
    /// operator owns, and the content around the missing end is worth having.
    ///
    /// If the record cannot be fetched -- the phone is offline, or the host's
    /// page budget keeps cutting it away -- the stale turns are **settled** by
    /// ``settlingStaleRuns(in:)`` and the settlement is written down, so the
    /// screen says "已结束" rather than counting a turn that is over. Writing it
    /// down also stops every later refresh from paying for this repair again;
    /// a cache written before this policy existed is settled at draw time by the
    /// same rule, so opening the conversation offline tells the same truth.
    ///
    /// - Parameter sessionId: the session whose merge produced the shape.
    /// - Returns: whether the conversation on disk changed. The caller re-reads
    ///   it then, because the page needed to repair an end is also older
    ///   conversation the screen should now hold.
    @discardableResult
    private func repairStaleRunningTurns(for sessionId: String) async -> Bool {
        var changed = false
        for _ in 0..<Self.staleRunRepairRounds {
            guard let cached = await conversations.load(sessionId: sessionId),
                  let stale = staleRunningTurn(in: cached.turns ?? [])
            else { return changed }
            if let before = stale.beforeSeq {
                var ceiling = before
                var repaired = false
                for _ in 0..<Self.staleRunRepairPages {
                    // Without a socket the next round trip cannot land, and the
                    // turns below are settled rather than left counting.
                    guard connection != nil else { break }
                    // A background refresh is spending an assertion it must not
                    // outlive; the page below is a request like any other.
                    if let deadline = backgroundDeadline,
                       !BackgroundSync.mayStartRequest(now: Date(), expiresAt: deadline) {
                        break
                    }
                    do {
                        let page = try await messages(sessionId: sessionId, beforeSeq: ceiling)
                        // A page with nothing in it, or one that did not move
                        // back, is the host saying there is nothing older here;
                        // asking again would loop.
                        guard !page.records.isEmpty,
                              let oldest = page.oldestSeq,
                              oldest < ceiling
                        else { break }
                        let stored = await conversations.update(sessionId: sessionId) { existing in
                            let known = existing ?? CachedConversation(
                                sessionId: sessionId,
                                items: [],
                                throughSeq: nil,
                                turns: [],
                            )
                            return Self.folding(older: page, into: known, sessionId: sessionId)
                        }
                        if staleRunningTurn(in: stored.turns ?? []) == nil {
                            repaired = true
                            break
                        }
                        // The missing end is above the stale turn's own start:
                        // once a page reaches back past that, the whole range
                        // has been read and the record is not in the log this
                        // host serves.
                        if let start = stale.turn.orderSeq, oldest <= start { break }
                        ceiling = oldest
                    } catch {
                        if !Task.isCancelled {
                            log.add(
                                .cache,
                                "session \(sessionId): could not repair a turn end a page stepped over",
                            )
                        }
                        break
                    }
                }
                if repaired {
                    changed = true
                    log.add(
                        .cache,
                        "session \(sessionId): recovered the end of turn \(stale.turn.turn.map(String.init) ?? "?")",
                    )
                    continue
                }
            }
            // A cancelled task is a screen going away or a background assertion
            // running out; it must not keep doing disk work, and a settlement
            // logged as a decision nobody made would be the same mistake in the
            // log. The draw-time rule still settles it on screen.
            if Task.isCancelled { return changed }
            await settleStaleRunningTurns(for: sessionId)
            log.add(
                .cache,
                "session \(sessionId): settled a turn a later turn proved is over; its end record is missing",
            )
            return true
        }
        // The bound was reached with a stale run still held: one skipped window
        // lost more endings than the rounds allow. Settle what is left rather
        // than leave the screen counting it.
        if !Task.isCancelled,
           let cached = await conversations.load(sessionId: sessionId),
           staleRunningTurn(in: cached.turns ?? []) != nil {
            await settleStaleRunningTurns(for: sessionId)
            log.add(
                .cache,
                "session \(sessionId): settled the turns a later turn proved are over; their end records are missing",
            )
            changed = true
        }
        return changed
    }

    /// Write the settled turns down, so no later screen counts a turn that is
    /// over. See ``repairStaleRunningTurns(for:)``.
    ///
    /// - Parameter sessionId: the session to settle.
    private func settleStaleRunningTurns(for sessionId: String) async {
        // Nothing to settle into a cache that no longer exists: the update would
        // write an empty conversation back, which is the opposite of what the
        // operator asked for when the cache went away.
        guard await conversations.load(sessionId: sessionId) != nil else { return }
        await conversations.update(sessionId: sessionId) { known in
            CachedConversation(
                sessionId: sessionId,
                items: known?.items ?? [],
                throughSeq: known?.throughSeq,
                syncedAt: known?.syncedAt ?? Date(),
                hasMore: known?.hasMore ?? false,
                turns: settlingStaleRuns(in: known?.turns ?? []),
                oldestSeq: known?.oldestSeq,
                stats: known?.stats,
                deliveredSeq: known?.deliveredSeq,
            )
        }
    }

    /// The last usage frame stored on this phone, if any.
    /// - Parameter sessionId: the session.
    /// - Returns: the frame, or `nil` when nothing is stored.
    func cachedStats(for sessionId: String) async -> SessionStatsFrame? {
        await conversations.load(sessionId: sessionId)?.stats
    }

    /// Keep a usage frame beside the session's conversation.
    ///
    /// Read-modify-write, because the file holds both: replacing it with just
    /// the frame would throw the history away.
    ///
    /// - Parameters:
    ///   - frame: what the host sent.
    ///   - sessionId: the session it belongs to.
    private func storeStats(_ frame: SessionStatsFrame, for sessionId: String) async {
        // One step, for the same reason: this runs from the usage read while a
        // page may be being folded in beside it, and the file holds both.
        await conversations.update(sessionId: sessionId) { existing in
            CachedConversation(
                sessionId: sessionId,
                items: existing?.items ?? [],
                throughSeq: existing?.throughSeq,
                syncedAt: existing?.syncedAt ?? Date(),
                hasMore: existing?.hasMore ?? false,
                turns: existing?.turns,
                oldestSeq: existing?.oldestSeq,
                stats: frame,
                deliveredSeq: existing?.deliveredSeq,
            )
        }
    }

    /// Read a session's recent log, as items a view can draw.
    ///
    /// - Parameter sessionId: the session to read.
    /// - Returns: the items, oldest first.
    func conversation(for sessionId: String) async -> [ConversationItem] {
        guard connection != nil else { return [] }
        do {
            // A full tail on purpose: this returns items to draw without folding
            // them into the cache, so it holds nothing to make an incremental
            // claim from. `.empty` keeps it that way even when the host has
            // already delivered a page to this device for a cache this path does
            // not read.
            let result = try await messages(sessionId: sessionId, afterSeq: .empty)
            lastError = nil
            return result.conversationItems()
        } catch {
            // Said out loud. This used to return an empty array, which drew the
            // same "no messages" screen as a session that genuinely has none --
            // so a broken read looked like an empty conversation, and there was
            // nothing on screen to say which it was.
            let message = Self.describe(error, authority: host?.authority ?? host?.baseURL)
            if !message.isEmpty { lastError = message }
            return []
        }
    }

    /// Read one page of a session's log.
    ///
    /// `RESPONSE_TOO_LARGE` is the one host failure whose answer is a *different*
    /// request rather than a retry of the same one: the page was real and the
    /// transport could not carry it, so re-sending it asks for the same refusal.
    /// A quarter of the size usually fits, and the alternative -- reporting
    /// failure -- puts nothing on the screen for a conversation that exists and
    /// that the host is willing to summarise.
    ///
    /// A delegated child's page is read through the same call, and the parent
    /// travels with it. The host does not address a child as a session -- it
    /// answers `session/agent-busy` ("subagent Sessions require their durable
    /// parent address") and refuses the read before touching the log -- so a
    /// request that named only the child's id could never page it at all. The
    /// lineage is on the row this phone was already given, so it is resolved
    /// here rather than at each of the three call sites that read a page.
    ///
    /// - Parameters:
    ///   - sessionId: the session to read.
    ///   - beforeSeq: the log position to page back from, when paging.
    ///   - afterSeq: what this phone already holds; only newer records travel.
    ///   - maxMessages: how much to ask for first.
    /// - Returns: the page.
    /// - Throws: the host's failure, when asking for less did not help either.
    private func messages(
        sessionId: String,
        beforeSeq: Int? = nil,
        afterSeq: SessionMessagesCursor = .unstated,
        maxMessages: Int = 200,
    ) async throws -> SessionMessagesResult {
        // Only a delegated child has one. A fork carries a parent and is not a
        // subagent -- it is the operator's own conversation, addressable as a
        // session like any other, and sending a parent for it would be a claim
        // about a log that is not a child's.
        let parentSessionId: String? = sessions
            .first { $0.sessionId == sessionId && $0.isSubagent }?
            .parentSessionId
        var ask = maxMessages
        while true {
            var fields: [String: JSONValue] = [
                "sessionId": .string(sessionId),
                // The host trims the page to what the transport can carry;
                // asking for more only costs a bigger request.
                "maxMessages": .number(Double(ask)),
            ]
            if let parentSessionId { fields["parentSessionId"] = .string(parentSessionId) }
            if let beforeSeq { fields["beforeSeq"] = .number(Double(beforeSeq)) }
            // `.unstated` leaves the key out on purpose: the host may then answer
            // from what it has already delivered to this device.
            if let cursor = afterSeq.fieldValue { fields["afterSeq"] = cursor }
            do {
                return try await call(
                    "session.messages",
                    payload: .object(fields),
                    as: SessionMessagesResult.self,
                )
            } catch let error as MizarError {
                guard let smaller = error.smallerPage(than: ask) else { throw error }
                log.add(
                    .request,
                    "session \(sessionId): the answer was too large for \(ask) messages; asking for \(smaller)",
                )
                ask = smaller
            }
        }
    }

    /// Read one session's usage frame.
    /// - Parameter sessionId: the session to read.
    /// - Returns: the frame, or `nil` when it could not be read.
    func stats(for sessionId: String) async -> SessionStatsFrame? {
        guard connection != nil else {
            statsError = "Not connected to the computer."
            return nil
        }
        do {
            let payload = JSONValue.object(["sessionId": .string(sessionId)])
            let result = try await call(
                "session.stats",
                payload: payload,
                as: SessionStatsResult.self,
            )
            statsError = nil
            // Merged, not replaced, and returned merged. The host answers each
            // field from its own projection, so a reply from a session whose
            // agent is cold carries no title, no model and no context pressure
            // -- and assigning that over the frame the phone already had is what
            // took those three off the screen a moment after drawing them.
            let known = await cachedStats(for: sessionId)
            guard let frame = result.stats else {
                // An answer with no frame at all. Same rule: it says nothing, so
                // it changes nothing.
                return known
            }
            let merged = frame.merging(known)
            // A permission switch just accepted here is confirmed by the host's
            // projection arriving in this frame. Once it has, the local override
            // has nothing left to say -- and keeping it would let a session id
            // reused by a later session read somebody else's answer as true.
            if let override = appliedPermissions[sessionId], override == merged.permissionPreset {
                appliedPermissions.removeValue(forKey: sessionId)
            }
            // Written down as well as returned. The figures above the composer
            // are read from this, and a session screen that has to wait for the
            // network before it can say which model is answering says nothing at
            // all when the network does not come back -- which on a phone is the
            // ordinary case.
            await storeStats(merged, for: sessionId)
            return merged
        } catch {
            // Reported rather than swallowed. This returned `nil` for every
            // failure, so a decode problem and a session with no usage looked
            // the same on screen -- which is how "the usage screen never loads"
            // stayed unexplained through several rounds.
            let message = Self.describe(error, authority: host?.authority ?? host?.baseURL)
            if !message.isEmpty { lastError = message }
            statsError = message.isEmpty ? "The computer did not answer." : message
            return nil
        }
    }

    /// Tell the host where to reach this phone, and whether it is on screen.
    ///
    /// Called on every connection, every time iOS issues a device token, and every
    /// time the Live Activity's push token changes. All three are needed: the
    /// tokens arrive once and the connection is rebuilt constantly, and a
    /// registration sent on a socket that has since been replaced is a
    /// registration the host never saw.
    ///
    /// The payload carries the Live Activity's token as optional
    /// `"liveActivityToken"`, and its absence is the contract's way of saying "no
    /// card is up": the host clears whatever it held, so the relay stops sending
    /// end pushes to an address whose activity is gone. That is why the field is
    /// omitted rather than sent as null -- the frozen wire contract says absent
    /// means clear, and one rule is easier to keep than two.
    ///
    /// Best-effort throughout. A phone that cannot be notified is a worse app,
    /// not a broken one, and an error here would be a failure screen over a
    /// feature the operator may not even want.
    func syncPushRegistration() async {
        // The kernel answers `push.register` with `{registered: false}` -- it has
        // no push channel -- so registering is a round trip that can only say
        // no. Skipped here rather than left to the kernel's polite refusal.
        guard !isLocalAgentMode else { return }
        guard let connection, let token = PushRegistration.storedToken else { return }
        var fields: [String: JSONValue] = [
            "token": .string(token),
            "environment": .string(PushRegistration.environment),
            "locale": .string(PushRegistration.locale),
        ]
        // Read at the moment of sending rather than remembered from when the app
        // started: an activity's token can be issued or forgotten while this
        // process is running, and a copy taken at launch would be either missing
        // or already dead.
        let liveActivityToken = LiveActivityPushTokenStore.stored()
        if let liveActivityToken { fields["liveActivityToken"] = .string(liveActivityToken) }
        // The address that can start a card rather than end one. Carried even
        // when no card is up: that is exactly the state it is for, and unlike
        // `liveActivityToken` its absence does not mean anything has ended.
        let liveActivityStartToken = LiveActivityStartTokenStore.stored()
        if let liveActivityStartToken { fields["liveActivityStartToken"] = .string(liveActivityStartToken) }
        let payload = JSONValue.object(fields)
        do {
            _ = try await loggedCall("push.register", payload: payload, on: connection, as: PushRegistrationResult.self)
            // How long the tokens are, never the tokens: see ``ActivityLog``. A
            // Live Activity token is an address for one card on this phone, and
            // the relay can end that card with it; this log is exportable.
            log.add(
                .push,
                "registered with the host: \(token.count) characters, \(PushRegistration.environment), \(PushRegistration.locale)"
                    + "; live activity token "
                    + (liveActivityToken.map { "held (\($0.count) characters)" } ?? "none")
                    + "; start token "
                    + (liveActivityStartToken.map { "held (\($0.count) characters)" } ?? "none"),
            )
        } catch {
            // Nothing to show: a phone that cannot be notified is a worse app,
            // not a broken one. Worth a line in the log all the same, because
            // "notifications never arrive" is otherwise indistinguishable from
            // "the host was never told where to send them".
            log.add(.push, "registration failed: \(Self.describe(error))")
        }
        await sendPresence()
    }

    /// Report whether this app is on screen.
    ///
    /// Its own method rather than folded into the registration, because it runs
    /// on every app switch and the registration tells the relay where the phone
    /// is. Together they would put an HTTP request to the relay behind every
    /// switch away from the app.
    ///
    /// Coming back to the foreground is also one of the moments the Live Activity
    /// is decided at, and the most important one: the operator is looking, so a
    /// card left over from a finish nobody's local end reached -- a relay end push
    /// that did not land, an activity from an older build -- comes down for good;
    /// and a session that started while the phone was in a pocket gets its
    /// activity now, because a start is only documented to work from here.
    ///
    /// - Parameter foreground: whether the app is in the foreground.
    func setPresence(foreground: Bool) async {
        self.foreground = foreground
        if foreground {
            await liveActivity.appOpened(
                sessions: sessions,
                conversations: conversations,
                sessionsAreKnown: sessionsAreKnown,
                titles: titles,
            )
        }
        await sendPresence()
    }

    /// Whether the app last told the host it was on screen.
    private var foreground = true

    private func sendPresence() async {
        guard let connection else { return }
        let payload = JSONValue.object(["foreground": .bool(foreground)])
        _ = try? await loggedCall("push.presence", payload: payload, on: connection, as: AcceptanceResult.self)
    }

    /// Forget this phone's notification endpoint.
    ///
    /// Called when the operator unpairs, so a phone that has been detached stops
    /// being woken for a machine it no longer knows about.
    func forgetPushRegistration() async {
        guard let connection else { return }
        _ = try? await loggedCall("push.unregister", on: connection, as: PushUnregisterResult.self)
        log.add(.push, "asked the host to forget this phone's notification endpoint")
    }

    /// Register for remote notifications if the operator has already agreed.
    ///
    /// Runs on every launch. The prompts above deliberately happen once, and iOS
    /// only offers each permission once anyway -- so somebody who tapped "Don't
    /// Allow" and then changed their mind in iOS Settings would otherwise have
    /// to reinstall the app before a single notification could arrive. Asking
    /// Apple for a token when permission is already granted costs nothing and
    /// closes that hole.
    func ensurePushRegistration() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard settings.authorizationStatus == .authorized
            || settings.authorizationStatus == .provisional
        else {
            // Forgets a token from a previous grant. The operator can revoke
            // permission in iOS Settings at any time, and a token that outlives
            // the permission is a row on the computer's roster that pushes into
            // nothing.
            PushRegistration.storedToken = nil
            log.add(.push, "no notification permission (\(settings.authorizationStatus.rawValue)); no token kept")
            return
        }
        log.add(.push, "notification permission is in place; asking Apple for a token")
        await Permissions.registerForRemoteNotifications()
    }

    /// Ask for what the app cannot do without, on the first launch after install.
    ///
    /// Two prompts and no more. Notifications, because a phone that cannot be
    /// told anything is a phone the operator has to keep opening; and the local
    /// network, because the direct route to a computer on the same Wi-Fi is refused
    /// silently without it -- which is the worst kind of failure, since the app
    /// looks connected and never is.
    ///
    /// Asked here rather than where each is first needed, because both arrive as
    /// system alerts and an alert during pairing reads as the pairing failing.
    ///
    /// The camera is asked for where it is used -- on the scan button -- and that
    /// is the whole reason this file has a comment about what it leaves out.
    ///
    /// Once ever, tracked in `UserDefaults`: iOS only offers each of these once
    /// anyway, and re-requesting a permission the operator already refused does
    /// nothing but burn a turn.
    func requestFirstRunPermissions() async {
        guard !Self.launchSkipsPermissions else { return }
        guard !UserDefaults.standard.bool(forKey: Self.permissionsAskedKey) else { return }
        UserDefaults.standard.set(true, forKey: Self.permissionsAskedKey)
        log.add(.app, "first launch: asking for notification and local-network permission")
        await Permissions.requestNotifications()
        // Only if the answer was yes. Registering regardless gave a phone that
        // tapped "Don't Allow" a token anyway, which it then handed to the computer --
        // so the host logged a healthy registration for a phone that could never
        // show the notification it was being sent.
        await ensurePushRegistration()
        // Sequenced rather than concurrent: two alerts at once is one alert
        // dismissed by reflex, and this one has to be read to be answered.
        await Permissions.requestLocalNetwork()
    }

    /// Whether this launch should skip the system prompts.
    ///
    /// For UI tests, which run against a fresh install and would otherwise be
    /// answered by a system alert instead of by the app.
    private static var launchSkipsPermissions: Bool {
        ProcessInfo.processInfo.arguments.contains("-mizarSkipPermissionPrompts")
    }

    /// Where "the operator has been asked" is remembered.
    private static let permissionsAskedKey = "mizar.permissionsAsked"

    /// Download everything once, with the whole screen reporting how it is going.
    ///
    /// `defer`, not a happy-path assignment: a cancelled load -- and a phone
    /// switching away mid-download is the ordinary case -- must not leave the
    /// full-screen progress view up for good.
    private func runFirstLoad() async {
        firstLoad = true
        defer { firstLoad = false }
        await syncAllConversations()
    }

    /// Complete pairing with a scanned target.
    ///
    /// A QR from plugin 0.8.5 on carries two routes to the same computer: the
    /// direct address it is listening on, and the relay its room is reachable
    /// through. Only one of them can answer for a given phone -- cellular, a
    /// Wi-Fi that isolates clients, and a refused local-network permission all
    /// rule out the direct one -- so pairing tries the whole plan and fails only
    /// when no route gets an answer. ``PairingClient`` owns the fallback rule;
    /// this method logs each route that failed, then opens the first socket over
    /// the route that worked.
    ///
    /// - Parameters:
    ///   - target: the decoded QR payload.
    ///   - deviceName: what to call this device in the host's roster.
    func pair(with target: PairingTarget, deviceName: String) async {
        phase = .connecting
        // A naming prompt for a *previous* machine must not survive into this
        // pairing. It is presented over the main screen, and when the machine
        // underneath it is replaced its content looks up the host and finds
        // either the wrong one or none -- an empty sheet that does not draw a
        // skip button and quietly keeps the next sheet from being presented.
        // The operator cannot see it and cannot dismiss it, and the model picker
        // then does nothing when tapped. Clearing the request dismisses it; the
        // new machine asks for its own name after it has connected.
        pendingNameHostId = nil
        log.add(.connection, "pairing with \(target.authority ?? target.baseURL ?? "unknown address") as \(deviceName)")
        do {
            // The identity headers, so a pair through a relay is attributed to
            // this install rather than to an anonymous hash of the room. Signed
            // out this is only the client id, which is exactly right: the
            // pairing request creates the device, there is no account behind it
            // yet. The client attaches them to relay attempts only -- a direct
            // pairing goes to the operator's own computer, which meters nothing
            // and has no use for an account hash.
            //
            // One transport per route, because the route carries the timeout:
            // the direct attempt gets a short leash, which is what makes falling
            // through to the relay a fallback rather than a second wait.
            let client = PairingClient(
                makeTransport: { URLSessionHTTPTransport(timeout: $0.timeout) },
                headers: account.identity.headers,
            )
            let outcome = try await client.pair(
                target: target,
                deviceName: deviceName,
                deviceModel: Self.deviceModel,
            )
            let paired = outcome.host
            try await credentials.save(paired)
            log.add(
                .connection,
                "paired with \(paired.hostName) (\(paired.hostId)) over "
                    + Self.routeName(outcome.route.endpoint),
            )
            hosts = try await credentials.loadAll().sorted { $0.pairedAt < $1.pairedAt }
            // A pairing is the operator saying "this is my computer, on this
            // network". Both transport switches default to off, and the route
            // planner gates a direct endpoint on `localNetworkFirst` -- so the
            // first connect after scanning the code on the computer's own screen
            // was refused with "The transport switches are off, so there is no
            // route to this computer", on a phone that had just been shown that
            // address. The switches the pairing implies are turned on for it; the
            // operator can still turn either back off in settings.
            if paired.authority != nil {
                if !settings.values.localNetworkFirst {
                    settings.values.localNetworkFirst = true
                }
                if !settings.values.directConnection {
                    settings.values.directConnection = true
                }
            }
            // Pairing a second machine is a change of machine like any other, and
            // it used to leave the first one's socket open: the new connection
            // replaced the reference without closing what it replaced, and every
            // value scoped to the old host stayed in memory. Dropping the
            // connection first makes "what belongs to one computer" the same rule on
            // the launch-pairing path as it is on the host list.
            disconnectCurrent()
            modelChoice = [:]
            host = paired
            LastOpenedHostStore.store(paired.hostId)
            // The initializing screen takes over here, not at the download:
            // between the pairing and the download there is a connect, and the
            // shell it would briefly expose has nothing to draw yet. From the
            // operator's side the scan landed straight into "Setting up".
            firstLoad = true
            // Offered once, now, while the operator still knows which machine
            // they just scanned. The connection is opened first so the name is
            // asked for over a working screen rather than a spinner, and over the
            // route that just paired so a working pairing does not spend the
            // other route's timeout before using the one that answered.
            try await connect(using: paired, preferring: outcome.route.endpoint)
            // The history comes down before anything else, and this time it is
            // the whole screen.
            //
            // It used to be a background task with a spinner in a toolbar, on
            // the reasoning that the operator should see the app working rather
            // than a dialog. Measured against a real pairing, the opposite is
            // true: until this has run, every screen is empty -- no sessions, no
            // titles, no figures -- and an empty app is indistinguishable from a
            // broken one. A first pairing is the one moment where a progress
            // dialog is the honest thing to show.
            //
            // Also before the naming prompt: that prompt belongs to the session
            // screen, and the session screen is not in the hierarchy while this
            // is.
            await runFirstLoad()
            // And a beat before the prompt. The download screen is replaced by
            // the session screen right here, and the session screen may still be
            // closing its sidebar or arriving in its place: a window hung off a
            // layout that is still moving is dismissed by the movement, and the
            // prompt that was meant to be asked once is gone before it can be
            // answered. Short enough that nobody notices, long enough that the
            // screen is still.
            try? await Task.sleep(for: .milliseconds(700))
            pendingNameHostId = paired.hostId
        } catch {
            if error is CancellationError || Task.isCancelled {
                // The task that started this pairing went away (a view rebuilt
                // while the handshake was in flight). The pairing did not fail;
                // the next start will try again. Showing "Cannot reach the
                // computer" here is what made a first launch look broken when
                // nothing was.
                log.add(.connection, "pairing cancelled before it finished")
                firstLoad = false
                hasStarted = false
                return
            }
            // One line per route that was tried, then the answer to act on. A
            // pairing that fell through the LAN to the relay and then failed
            // there is a different problem from one that never left the phone,
            // and the log is the only place that difference is visible.
            let failure = error as? PairingFailure
            for attempt in failure?.attempts ?? [] {
                log.add(
                    .connection,
                    "pairing route \(Self.routeName(attempt.route.endpoint)) failed: "
                        + Self.describe(
                            attempt.error,
                            authority: attempt.route.address,
                            throughServer: attempt.route.isRelay,
                        ),
                )
            }
            // The error itself, not its `finalError`: `describe` ranks the plan
            // and knows which route each reason came from.
            let message = Self.describe(
                error,
                authority: failure?.attempts.last?.route.address
                    ?? target.authority ?? target.baseURL,
            )
            log.add(.connection, "pairing failed: \(message)")
            // A pairing that died on the way in must not leave the initializing
            // screen up: the failure screen behind it is the one that answers.
            firstLoad = false
            phase = .failed(message)
        }
    }

    /// How long the relay waits while a direct route is being dialled.
    ///
    /// The launch race's only ordering rule. A computer on the same network
    /// answers a WebSocket upgrade in tens of milliseconds, so this is generous
    /// enough that a direct route which *can* answer always wins -- and short
    /// enough that a direct address which cannot answer stops being the thing
    /// the operator is waiting for.
    private static let launchDirectHeadStart: Duration = .milliseconds(400)

    /// One route's answer in the launch race.
    private struct Answered: Sendable {
        let endpoint: PairedHost.Endpoint
        let connection: MizarConnection
        let welcome: WelcomeFrame
    }

    /// Every route that failed, in the order the answers arrived.
    ///
    /// Carries the routes, not only the errors: which sentence the failure
    /// deserves depends on whether the route went through the relay, and that is
    /// known here and nowhere downstream.
    private struct LaunchFailure: Error, Sendable {
        let attempts: [(route: PairedHost.Endpoint, error: any Error)]
    }

    /// What one racing route came back with.
    private enum LaunchDial: Sendable {
        case answered(Answered)
        case failed(route: PairedHost.Endpoint, error: any Error)
        case skipped
    }

    /// Put a connection failure on screen, and keep it apart from request errors.
    ///
    /// The two are shown by one banner (``problem``) but they are not the same
    /// fact, and a request that fails because the socket is gone must not
    /// overwrite the sentence that says why the socket is gone.
    ///
    /// - Parameters:
    ///   - error: what the dial failed with.
    ///   - authority: the address that was being dialled, when known.
    private func failConnection(_ error: any Error, authority: String? = nil) {
        let message = Self.describe(error, authority: authority)
        connectionError = message.isEmpty ? nil : message
        linkFailure = linkStatus(for: error, authority: authority)
        phase = .failed(message)
    }

    /// The link bar's reading of a dial that failed.
    ///
    /// The same ranking the sentence uses: a plan of routes is represented by
    /// the attempt that proves the most, so the cross and the words agree about
    /// which half of the trip is being described.
    ///
    /// - Parameters:
    ///   - error: what the dial threw.
    ///   - authority: the address it was dialling, when known.
    /// - Returns: the bar's status, or `nil` when the error says nothing about a
    ///   link (a cancelled task, for one).
    private func linkStatus(for error: any Error, authority: String?) -> LinkStatus? {
        if let failure = error as? LaunchFailure {
            let attempts = failure.attempts.map {
                RouteFailure(
                    isRelay: ReconnectPlan.isRelay($0.route),
                    address: Self.routeDescription($0.route).address,
                    error: $0.error,
                )
            }
            guard let best = Self.best(of: attempts) else { return nil }
            return LinkStatus.failure(best.error, authority: best.address, isRelay: best.isRelay)
        }
        if error is MizarError {
            // The guard inside ``connect(using:preferring:)``: no address to
            // dial, or every route the pairing has is switched off. Nothing was
            // dialled, so the cross sits on the phone's own side of the picture.
            let topology = LinkStatus.plannedTopology(for: host)
            return LinkStatus(
                topology: topology,
                connected: false,
                broken: topology == .relay ? .phoneToRelay : .phoneToComputer,
                label: .computerUnreachable,
            )
        }
        guard let authority else { return nil }
        return LinkStatus.failure(error, authority: authority, isRelay: false)
    }

    /// Which picture a live route draws.
    ///
    /// Only the relay adds a device: a LAN address, a tailnet one and a punched
    /// path all end at the computer itself, and drawing the relay beside them
    /// would claim a hop the frames do not take.
    private static func topology(of endpoint: PairedHost.Endpoint) -> LinkStatus.Topology {
        if case .relay = endpoint { return .relay }
        return .direct
    }

    /// Open the socket and load the first screen's data.
    ///
    /// Every route the pairing knows about is dialled **at the same time**, and
    /// the first one to answer wins. That is the fix for a launch that felt
    /// broken on a phone that had left its own network: the routes used to be
    /// tried one after another, so a dead LAN address was paid for in full --
    /// the direct leash, six seconds -- before the relay that would have
    /// answered in one was even started, and the operator watched the sum of
    /// two attempts when only one of them could ever have worked.
    ///
    /// The order still means something, and this is now the only thing it
    /// means: **the local network gets a head start, alone**. The punched route
    /// and every relay are held back by ``launchDirectHeadStart``, so a computer
    /// on the same network answers first and the phone stays off the relay --
    /// faster, and unmetered. When the direct address is dead the other routes
    /// are already dialling by the time the first packet would have been lost, so
    /// the fallback costs the head start instead of the direct timeout.
    ///
    /// Starting the punched route at the same time as the relay is deliberate:
    /// the two are alternatives to the same lost LAN, not a sequence, and making
    /// P2P wait behind the relay would hand the slower of the two every race.
    ///
    /// A loser is cancelled and closed, never left half-open: a race that leaked
    /// a socket would leave the host with a second device session for every
    /// launch.
    ///
    /// A pairing that has just completed passes the route it paired over as
    /// `preferred`, so it races in front of the rest of the pairing.
    ///
    /// - Parameters:
    ///   - host: the pairing to connect with.
    ///   - preferred: the route that just paired, when this connect follows a
    ///     pairing; `nil` opens the pairing's own order.
    private func connect(
        using host: PairedHost,
        preferring preferred: PairedHost.Endpoint? = nil,
    ) async throws {
        phase = .connecting
        // A new dial is not the last one: the bar goes back to "connecting"
        // rather than keeping the cross from the attempt before it.
        linkFailure = nil
        // The agent this connection is for, before anything reads a list. Every
        // dial comes through here -- a launch, a tap on the computer list, a
        // reconnect after the relay moved -- and the choice belongs to the
        // pairing, so deriving it here is what keeps a relaunch from falling
        // back to "all agents" and drawing three agents' folders under one name.
        engineScope = host.engine.flatMap(AgentEngine.init(rawValue:))
        // Before the first request, not after it. Everything below waits on a
        // machine that may be asleep, and a session list that is empty until a
        // round trip lands is empty for as long as the round trip takes -- which
        // on a phone is how the operator spends the first several seconds of
        // every launch.
        await loadIndex(for: host.hostId)
        // The pairing's order when nothing is preferred; the route that just
        // answered in front of it when something is.
        let endpoints = ReconnectPlan.routes(
            endpoints: host.endpoints,
            active: preferred,
            allowingLocalNetwork: settings.localNetworkFirst,
            allowingDirectPath: settings.directConnection,
        )
        guard !endpoints.isEmpty else {
            // Two different silences, told apart: a pairing with no address at
            // all, and one whose every address the operator has switched off.
            // The second is fixable from the settings screen and says so.
            let error = host.endpoints.isEmpty
                ? MizarError(code: "NO_ENDPOINT", message: "this pairing has no address to dial")
                : MizarError(
                    code: "ROUTE_NOT_ALLOWED",
                    message: String(
                        localized: "The transport switches are off, so there is no route to this computer. Turn on the local network or the direct connection to reconnect.",
                    ),
                )
            phase = .failed(error.message)
            throw error
        }

        // The local network goes first, alone, for a moment. Everything that is
        // not the operator's own network -- the punched route and every relay --
        // is held back by the same head start, so the order the operator asked
        // for is the order the dials start in: LAN, then P2P and relay together,
        // and whichever of the two answers first wins.
        //
        // A pairing with no direct address -- the usual one for a computer that
        // listens only on loopback -- has nothing to prefer, so its dials all
        // start at once.
        let hasDirect = endpoints.contains { if case .direct = $0 { return true } else { return false } }
        let dials = endpoints.map { endpoint in
            (
                endpoint: endpoint,
                connection: makeConnection(host: host, endpoint: endpoint),
                delay: hasDirect && !ReconnectPlan.isDirect(endpoint)
                    ? Self.launchDirectHeadStart
                    : .zero,
            )
        }

        // One line for the whole race, in the order the dials start: the log
        // used to carry a "dialling" line per attempt, and with the attempts
        // overlapping that is now a plan rather than a sequence.
        let plan = dials.map { dial in
            dial.delay > .zero
                ? "\(Self.routeName(dial.endpoint)) after \(dial.delay)"
                : Self.routeName(dial.endpoint)
        }
        log.add(.connection, "dialling " + plan.joined(separator: " and "))

        let answer: Answered
        do {
            answer = try await firstAnswer(in: dials)
        } catch let failure as LaunchFailure {
            log.add(.connection, "no route reached \(host.hostName); \(endpoints.count) tried")
            // The failure is thrown rather than its last error: the caller may
            // have to describe it again, and only the plan knows which route
            // each reason came from.
            let message = Self.describe(failure)
            connectionError = message.isEmpty ? nil : message
            linkFailure = linkStatus(for: failure, authority: nil)
            phase = .failed(message)
            throw failure
        }
        await adopt(answer, host: host)
    }

    /// Dial every route at once and return the first one that answers.
    ///
    /// The winner is decided by arrival, not by list position -- the list only
    /// decides who starts first (see ``connect(using:preferring:)``). Losing
    /// routes are cancelled the moment the winner is known, and each closes its
    /// own socket on the way out, so the group drains at the speed of a
    /// cancellation rather than at the speed of a timeout.
    ///
    /// - Parameter dials: the routes, each with the connection to dial it on and
    ///   how long to wait before starting.
    /// - Returns: the first route to complete its handshake.
    /// - Throws: ``LaunchFailure`` carrying one reason per route when none
    ///   answered.
    private func firstAnswer(
        in dials: [(endpoint: PairedHost.Endpoint, connection: MizarConnection, delay: Duration)],
    ) async throws -> Answered {
        var failures: [(route: PairedHost.Endpoint, error: any Error)] = []
        var winner: Answered?

        await withTaskGroup(of: LaunchDial.self) { group in
            for dial in dials {
                group.addTask {
                    if dial.delay > .zero {
                        do {
                            try await Task.sleep(for: dial.delay)
                        } catch {
                            // Cancelled before it started: the head start was
                            // still running when another route answered.
                            return .skipped
                        }
                    }
                    if Task.isCancelled { return .skipped }
                    do {
                        let welcome = try await dial.connection.connect()
                        return .answered(
                            Answered(
                                endpoint: dial.endpoint,
                                connection: dial.connection,
                                welcome: welcome,
                            ),
                        )
                    } catch {
                        // A route that lost the race was cancelled rather than
                        // answered. Its socket goes with it: a half-open one is
                        // a socket nobody reads and nobody closes.
                        await dial.connection.disconnect()
                        return Task.isCancelled
                            ? .skipped
                            : .failed(route: dial.endpoint, error: error)
                    }
                }
            }
            for await result in group {
                switch result {
                case .answered(let answer):
                    guard winner == nil else {
                        // A second route finished in the same tick. The first
                        // one answered first, so this one is closed.
                        await answer.connection.disconnect()
                        continue
                    }
                    winner = answer
                    // Cancels the sleepers and aborts the handshakes still
                    // waiting; each of those closes its own socket as it unwinds.
                    group.cancelAll()
                case .failed(let route, let error):
                    // After a winner these are cancellations, not answers.
                    guard winner == nil else { continue }
                    failures.append((route, error))
                    log.add(
                        .connection,
                        "route \(Self.routeName(route)) failed: "
                            + Self.describe(
                                error,
                                authority: Self.routeDescription(route).address,
                                throughServer: ReconnectPlan.isRelay(route),
                            ),
                    )
                case .skipped:
                    break
                }
            }
        }

        guard let winner else { throw LaunchFailure(attempts: failures) }
        return winner
    }

    /// Make an answered route the app's connection, and load the first screen.
    ///
    /// Everything that follows a handshake, in the order the screens need it:
    /// the socket becomes the app's, the route becomes the one the footer and
    /// the next reconnect read, and only then is the first data asked for.
    ///
    /// - Parameters:
    ///   - answer: the route that answered, with its open connection.
    ///   - host: the pairing it belongs to.
    private func adopt(_ answer: Answered, host: PairedHost) async {
        // A new subject, before the state below rather than after it:
        // everything here reads and writes host-scoped state, and the epoch is
        // what says which socket that state belongs to.
        nextConnectionEpoch += 1
        connectionEpoch = nextConnectionEpoch
        connection = answer.connection
        welcome = answer.welcome
        log.add(
            .connection,
            "connected to \(answer.welcome.hostName), protocol "
                + "\(answer.welcome.protocolVersion), over \(Self.routeName(answer.endpoint))",
        )
        activeEndpoint = answer.endpoint
        // A connection that landed on the alternate relay is the repair for a
        // stale stored URL: remember the one that actually answered before the
        // next reconnect starts from the old address again.
        if case .relay(let baseURL) = answer.endpoint, host.baseURL != baseURL {
            await rememberRelayBaseURL(baseURL)
        }
        await finishAdopting()
    }

    /// The on-device agent's handshake has completed: the same tail as a computer.
    private func adoptLocal(_ started: LocalAgentController.Started) async {
        // A new subject, exactly as a socket is: the epoch is what says whose
        // answers the host-scoped state belongs to.
        nextConnectionEpoch += 1
        connectionEpoch = nextConnectionEpoch
        connection = started.connection
        welcome = started.welcome
        log.add(
            .connection,
            "connected to the on-device agent (\(started.welcome.hostName)), protocol "
                + "\(started.welcome.protocolVersion), in process",
        )
        // No route: the frames never leave the process, so there is no address
        // to name and nothing to switch between.
        activeEndpoint = nil
        await finishAdopting()
    }

    /// Everything a freshly handshaken connection needs, whoever it is to.
    ///
    /// Split out so the two adopters cannot drift: the session list, the poll
    /// and the ready phase are the same facts whether the frames came off a
    /// socket or out of this process.
    private func finishAdopting() async {
        // A link is open, so whatever the last dial failed with is no longer
        // what is wrong.
        connectionError = nil
        linkFailure = nil
        phase = .ready
        // A launch's first read, and a reconnect's -- both automatic. The button
        // that a person would have tapped instead shows itself working; see
        // ``autoRefreshing``.
        beginAutomaticRefresh()
        await refreshSessions()
        endAutomaticRefresh()
        // Both are about reaching the phone from a computer: the push
        // registration that wakes this app, and the relay tier the host's
        // tunnel should use. The on-device agent has neither -- the kernel
        // answers `push.register` with `{registered: false}` and has no tunnel --
        // so this is one place the two hosts genuinely differ.
        if !isLocalAgentMode {
            // After the session list, so the first screen is not waiting on a
            // registration the operator never asked for. A round trip, not a
            // dependency: the app works identically whether or not it lands.
            await syncPushRegistration()
            // The plan may have changed while the app was unpaired or offline;
            // the first live socket is the first chance to align the tunnel's
            // relay.
            await syncRelayTier()
        }
        startInteractionPoll()

        if let requested = Self.launchSelectedSession {
            selectedSessionId = requested == "first" ? sessions.first?.sessionId : requested
        }
    }

    /// Build a connection for one route, not yet opened.
    ///
    /// The leash is per route, and it is what bounds a launch that has only one
    /// way in: the direct address gets six seconds because a local network that
    /// is going to answer at all answers quickly, and the relay gets twenty
    /// because a relay that is reachable but slow is still worth waiting for.
    /// When both are racing, the losing route is cancelled rather than timed
    /// out, so these numbers decide the lone-route case and the winner's
    /// patience -- not how long a fallback takes.
    ///
    /// - Parameters:
    ///   - host: the pairing to connect with.
    ///   - endpoint: which route to take.
    /// - Returns: the connection.
    private func makeConnection(
        host: PairedHost,
        endpoint: PairedHost.Endpoint,
    ) -> MizarConnection {
        // Only the direct attempt gets a short leash. A relay that is reachable
        // but slow should be waited for rather than abandoned for a route that
        // has already been ruled out.
        let timeout: TimeInterval
        switch endpoint {
        case .direct: timeout = 6
        case .relay: timeout = 20
        // The punch budget the kernel enforces is three seconds; five here leaves
        // room for a signaling channel that has to open first, and still bounds
        // the attempt to something shorter than the relay it may fall back to.
        case .p2p: timeout = 5
        }

        // The relay meters traffic by the two identity headers on the upgrade.
        // A direct connection goes to the operator's own computer over their own
        // network and is metered by nobody, so it carries none: sending an
        // account hash to a host that does not need it would be a credential
        // derivative leaving the phone for no reason.
        //
        // The paid relay is the one host that also needs proof: it refuses to
        // carry a session unless the account behind it is paying, and only the
        // token can answer that. So the token goes there and nowhere else — a
        // free relay would have nothing to verify it against.
        let relayHeaders: [String: String]
        switch endpoint {
        case .direct, .p2p:
            // A punched connection's bytes never reach the relay: it carries the
            // candidates and then gets out of the way. Sending it the account
            // hash on a socket it does not carry would be a credential
            // derivative leaving the phone for nothing.
            relayHeaders = [:]
        case .relay(let baseURL):
            var headers = account.identity.headers
            if AccountClient.isAccountHost(baseURL) {
                headers.merge(account.identity.sessionHeaders) { _, new in new }
            }
            relayHeaders = headers
        }

        let configuration: MizarConnection.Configuration
        switch endpoint {
        case .direct(let authority):
            configuration = .init(
                authority: authority,
                token: host.deviceToken,
                appVersion: Self.appVersion,
                deviceModel: Self.deviceModel,
                // The agent this pairing was opened for. The computer filters
                // everything it sends by it, and a token the relay scoped wins
                // over it on the computer's side, so this cannot widen anything.
                engine: host.engine,
                // The handshake is given the same leash as the dial. A socket
                // that opens and then says nothing is otherwise a screen stuck
                // on "Connecting…" for as long as the process lives, and this
                // route has already been given its chance by then.
                handshakeTimeout: .seconds(timeout),
                relayHeaders: relayHeaders,
            )
        case .relay(let baseURL):
            configuration = .init(
                authority: nil,
                token: host.deviceToken,
                appVersion: Self.appVersion,
                deviceModel: Self.deviceModel,
                engine: host.engine,
                baseURL: baseURL,
                handshakeTimeout: .seconds(timeout),
                relayHeaders: relayHeaders,
            )
        case .p2p(let relayBaseURL, let endpointId):
            configuration = .init(
                authority: nil,
                token: host.deviceToken,
                appVersion: Self.appVersion,
                deviceModel: Self.deviceModel,
                engine: host.engine,
                handshakeTimeout: .seconds(timeout),
                relayHeaders: relayHeaders,
                p2p: P2PRoute(relayBaseURL: relayBaseURL, endpointId: endpointId),
            )
        }

        // Which wire the frames travel on. A punched route is the same Mizar
        // protocol over a UDP stream the kernel negotiated, so the connection
        // above is unchanged and only the transport differs — which is what the
        // kernel's transport seam was for.
        let makeTransport: @Sendable () -> any WebSocketTransport
        switch endpoint {
        case .direct, .relay:
            makeTransport = { URLSessionWebSocketTransport(timeout: timeout) }
        case .p2p(let relayBaseURL, _):
            makeTransport = {
                P2PWebSocketTransport(
                    makeEngine: {
                        // Derived from the device token, so the identity is
                        // stable for the life of the pairing and needs no
                        // storage of its own.
                        MizarNetQUICEngine(identity: .device(forDeviceToken: host.deviceToken))
                    },
                    makeSignaling: {
                        guard let url = PairingURI.relaySignalWebSocketURL(baseURL: relayBaseURL) else {
                            throw MizarNetError.signalingFailed(reason: "the room does not form a URL")
                        }
                        let channel = WebSocketSignalingTransport(
                            socket: URLSessionWebSocketTransport(timeout: timeout),
                        )
                        try await channel.open(url: url)
                        return channel
                    },
                    // The desktop's signal endpoint says nothing until it
                    // knows whose channel this is, so the same token that
                    // authenticates the Mizar handshake goes first.
                    deviceToken: host.deviceToken,
                )
            }
        }

        return MizarConnection(configuration: configuration, makeTransport: makeTransport)
    }

    /// Why the last usage read failed, when it did.
    ///
    /// Separate from ``lastError`` because the usage screen needs to tell two
    /// things apart that both arrive as "no stats": a session that has never
    /// sent a request, and a read that did not happen. It showed the first for
    /// both, so a failure was reported to the operator as a fact about their
    /// session -- "This session has not sent a request" -- which is untrue and
    /// unfalsifiable from the screen. That is why "the usage query does not
    /// work" could not be diagnosed: the app was asserting the answer.
    private(set) var statsError: String?

    /// Why the last conversation read produced nothing, when it failed.
    ///
    /// The companion of ``statsError`` and for the same reason: "we could not
    /// ask" and "there is nothing there" are different answers, and the screen
    /// was giving the second for both.
    private(set) var conversationError: String?

    /// How a route reads in a log line.
    ///
    /// - Parameter endpoint: the route.
    /// - Returns: e.g. `direct 127.0.0.1:19390` or `relay https://…`.
    private static func routeName(_ endpoint: PairedHost.Endpoint) -> String {
        let described = routeDescription(endpoint)
        return "\(described.name) \(described.address)"
    }

    /// A route's kind and address, apart, for the archive.
    ///
    /// Separate from ``routeName(_:)`` because the JSON has somewhere to put each
    /// and a log line does not: `"route": "relay"` beside
    /// `"address": "wss://…"` is queryable, and one string is not.
    ///
    /// - Parameter endpoint: the route.
    /// - Returns: the kind, and the address it dials.
    private static func routeDescription(_ endpoint: PairedHost.Endpoint) -> (name: String, address: String) {
        switch endpoint {
        case .direct(let authority): ("direct", authority)
        // Named for what it is, not for the relay it borrows: `"p2p"` in the
        // archive is the answer to "did the direct path work", and calling it a
        // relay would make that question unanswerable.
        case .p2p(let relayBaseURL, let endpointId):
            ("p2p", "\(endpointId) via \(relayBaseURL)")
        case .relay(let baseURL): ("relay", baseURL)
        }
    }

    /// The hardware model, for the host's device roster and the log.
    static var deviceModel: String {
        #if targetEnvironment(simulator)
        "iOS Simulator"
        #else
        var info = utsname()
        uname(&info)
        let mirror = Mirror(reflecting: info.machine)
        let identifier = mirror.children.reduce(into: "") { partial, element in
            guard let value = element.value as? Int8, value != 0 else { return }
            partial.append(Character(UnicodeScalar(UInt8(value))))
        }
        return identifier.isEmpty ? "iPhone" : identifier
        #endif
    }

    /// The app's marketing version.
    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    }

    /// The build number, which is what tells two builds of one version apart.
    static var appBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
    }

    /// Version and build in one line, as the About section and the log show it.
    static var versionLine: String { "\(appVersion) (\(appBuild))" }

    /// The launch flags this process was started with, by name.
    ///
    /// Names, not values. `-mizarPairURI` carries a pairing code, and both this
    /// line and the archive it travels into exist to be read by somebody else.
    /// The scrubber in `MizarKit` would catch the code; not writing it is better
    /// than catching it.
    static var launchFlags: [String] {
        ProcessInfo.processInfo.arguments.filter { $0.hasPrefix("-") }
    }

    /// Whether an error is something the operator should be told about.
    ///
    /// A cancelled task is not a failure: it is a screen that went away or a
    /// request that got superseded, and both happen constantly in a list that
    /// reloads as you scroll. Showing them put "未能完成操作。（CancellationError
    /// 错误1。）" on screen for something nobody did wrong.
    ///
    /// - Parameter error: the error to judge.
    /// - Returns: whether to surface it.
    private static func isWorthReporting(_ error: any Error) -> Bool {
        if error is CancellationError { return false }
        if let urlError = error as? URLError, urlError.code == .cancelled { return false }
        return true
    }

    /// Render an error for a human.
    ///
    /// `String(describing:)` on a `URLError` produces the entire `UserInfo`
    /// dictionary, which is what this screen used to show: a page of
    /// `_kCFStreamErrorCodeKey=-2102` that is accurate and useless. A failure to
    /// reach a tailnet address now says so and names the fix.
    ///
    /// A plan of routes is described by the failure worth showing rather than by
    /// whichever error reached this function: see ``describe(failure:)``.
    ///
    /// - Parameters:
    ///   - error: the error to describe.
    ///   - authority: the address that was being reached, when known.
    ///   - throughServer: whether a relay sat between this phone and the computer.
    /// - Returns: text to put in front of the operator.
    private static func describe(
        _ error: any Error,
        authority: String? = nil,
        throughServer: Bool = false,
    ) -> String {
        if !isWorthReporting(error) { return "" }
        // A plan of routes carries its own addresses; the caller's `authority` is
        // one of them at best, and describing a relay's answer against the LAN
        // address is how the wrong sentence used to win.
        if let failure = error as? LaunchFailure {
            return describe(
                failure: failure.attempts.map {
                    RouteFailure(
                        isRelay: ReconnectPlan.isRelay($0.route),
                        address: routeDescription($0.route).address,
                        error: $0.error,
                    )
                },
            )
        }
        if let failure = error as? PairingFailure {
            return describe(
                failure: failure.attempts.map {
                    RouteFailure(isRelay: $0.route.isRelay, address: $0.route.address, error: $0.error)
                },
            )
        }
        if let mizar = error as? MizarError, !throughServer {
            // A host's own refusal is its answer, and the hop cannot improve on
            // it. Over a relay the diagnosis still runs, because a handshake
            // that never completed is the one host-shaped failure that is really
            // about the hop.
            return mizar.message
        }
        guard let authority else { return error.localizedDescription }
        return ConnectionDiagnosis.of(
            error,
            authority: authority,
            over: throughServer ? .server : .direct,
        ).message
    }

    /// One route's failure, as the picker below sees it.
    private struct RouteFailure {
        /// Whether this route went through the relay.
        let isRelay: Bool
        /// The address that route dialled.
        let address: String
        /// What it failed with.
        let error: any Error
    }

    /// The sentence for one route's failure.
    ///
    /// - Parameter failure: the route that failed.
    /// - Returns: text for the operator.
    private static func describe(_ failure: RouteFailure) -> String {
        describe(failure: [failure])
    }

    /// The sentence to show for a plan in which every route failed.
    ///
    /// Not the last failure to arrive: with the launch race that is usually the
    /// direct address timing out six seconds after the relay already said the
    /// computer is not connected, and the relay's answer is the one that
    /// explains the screen. So the failures are ranked by what they prove.
    ///
    /// - Parameter attempts: every route's failure.
    /// - Returns: the sentence for the most informative one.
    private static func describe(failure attempts: [RouteFailure]) -> String {
        guard let best = best(of: attempts) else { return "" }
        return describe(best.error, authority: best.address, throughServer: best.isRelay)
    }

    /// The failure worth showing, out of a plan that all failed.
    ///
    /// Split out of ``describe(failure:)`` because the link bar ranks the same
    /// way: the sentence and the cross have to be about the same attempt, or the
    /// words would say the relay was unreachable while the cross sat on the
    /// computer.
    ///
    /// - Parameter attempts: every route's failure.
    /// - Returns: the most informative one, or `nil` for an empty plan.
    private static func best(of attempts: [RouteFailure]) -> RouteFailure? {
        var best: RouteFailure?
        for attempt in attempts {
            if best == nil || weight(attempt) >= weight(best!) { best = attempt }
        }
        return best
    }

    /// How much a failure says about what is wrong.
    ///
    /// Four means the far end answered, which is always the most specific thing
    /// available: the relay saying "this room has no computer", or the computer
    /// itself refusing the token. Two and one are both "nothing answered", and
    /// the relay is ranked above the direct address because it is the route that
    /// is supposed to work from anywhere -- if it cannot be reached, that is the
    /// answer to "why can I not get to my computer".
    ///
    /// A `MizarError` only counts as an answer when its code is one this app
    /// knows. The dial-level ones (`CONNECTION_CLOSED`, `REQUEST_TIMEOUT`) are
    /// this side describing a socket that never got that far, and ranking them
    /// with the answers would let "the host closed the connection" beat a relay
    /// that said the computer is switched off.
    ///
    /// - Parameter failure: one route's failure.
    /// - Returns: its rank.
    private static func weight(_ failure: RouteFailure) -> Int {
        if failure.error is WebSocketUpgradeRefused { return 4 }
        if let mizar = failure.error as? MizarError, mizar.known != nil { return 4 }
        return failure.isRelay ? 2 : 1
    }
}
