//
//  MizarSettings.swift
//  MizarKit
//
//  What the operator has switched on, and where that is remembered.
//
//  Two rules shape this file.
//
//  **It is a value.** The whole of the app's preference state is one `struct`
//  with value semantics, so a test can hold two of them and compare, and the
//  store that owns the live one has exactly one place to persist from. The
//  alternative -- a `Bool` per switch scattered across the app -- is how a
//  switch ends up meaning one thing on the screen it is drawn on and another
//  where it is consulted.
//
//  **The decision is here, not in the view.** Which notification a push is, and
//  whether the operator wants it, are both answerable without UIKit, without a
//  notification centre and without a running app. That is the point: the screen
//  that draws the switches can only be as trustworthy as the function underneath
//  them, and this one is testable in a second with `swift test`.
//

import Foundation

// MARK: - What a push is about

/// A kind of notification the host sends.
///
/// Four, because four is how many decisions the operator can actually hold in
/// mind at once. A turn that finished is not the same news as a turn that died,
/// and neither is the same as a model waiting on an answer -- one is
/// informational, two are things somebody has to act on.
///
/// The wire, as the plugin's transport sends it, has three names:
/// `approval`, `question` and `turn-complete` (see `dsh/src/push/transport.ts`).
/// `turn-complete` deliberately covers both endings -- the wording in the title
/// says which -- so ``classify(kind:title:reason:)`` splits it here rather than
/// asking the operator to accept one switch for "a turn ended, somehow".
public enum NotificationKind: String, Sendable, CaseIterable, Codable {
    /// A turn ended the way it was meant to. 任务完成.
    case turnFinished = "turn-finished"
    /// A turn ended badly: an error, an abort, a stop. 任务中断.
    case turnInterrupted = "turn-interrupted"
    /// The model is blocked on a question. 模型询问.
    case question = "question"
    /// An approval is waiting. 权限授予.
    case approval = "approval"

    /// Wordings the plugin uses for a turn that did not finish.
    ///
    /// Taken from `turnWording` in `dsh/src/push/notifier.ts`, both languages,
    /// because the title is already localized by the time it reaches this phone
    /// and the app must not be the second place that decides what a Chinese
    /// string means. `任务已结束` / `Task finished` is *not* here: a turn that
    /// settled without a recorded reason is an ending, not a failure, and
    /// filing it under 任务中断 would make that switch mean "turns that ended in
    /// some way I did not expect".
    private static let interruptedWordings: Set<String> = [
        "任务出错", "任务已停止",
        "Task failed", "Task stopped",
    ]

    /// Reasons that mean the turn finished.
    private static let finishedReasons: Set<String> = [
        "completed", "complete", "done", "finished", "settled", "success", "ok",
    ]

    /// Reasons that mean the turn did not finish.
    ///
    /// Not sent by the transport today. Carried anyway: the relay passes a
    /// `reason` through untouched if a future plugin sends one, and a push that
    /// says `reason: "aborted"` should not need a new app build to be filed
    /// correctly.
    private static let interruptedReasons: Set<String> = [
        "error", "failed", "aborted", "interrupted", "stopped", "cancelled", "canceled", "timeout",
    ]

    /// Work out what a notification is about.
    ///
    /// - Parameters:
    ///   - kind: the `kind` from the notification's `userInfo`, as the relay
    ///     copied it from the plugin.
    ///   - title: the notification's title, which for `turn-complete` carries
    ///     the distinction the wire name does not.
    ///   - reason: a `reason` from the `userInfo`, when a host sends one.
    /// - Returns: the kind, or `nil` when this build does not know it.
    ///
    /// `nil` is an answer, and the caller is expected to show the notification
    /// for it. A push this build cannot name is a push from a newer host, and
    /// silently swallowing it because no switch mentions it would turn a future
    /// feature into a bug report about notifications that never arrive.
    public static func classify(
        kind: String?,
        title: String?,
        reason: String? = nil,
    ) -> NotificationKind? {
        guard let name = kind?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !name.isEmpty
        else { return nil }

        switch name {
        case "approval":
            return .approval
        case "question":
            return .question
        case "turn-interrupted", "turn-failed", "turn-aborted", "turn-stopped":
            return .turnInterrupted
        case "turn-finished", "turn-complete", "turn-completed":
            // A reason is a machine fact and beats a title, which is wording
            // somebody chose. An unknown reason falls through to the title
            // rather than being treated as either answer.
            switch reason?.lowercased() {
            case let reason? where interruptedReasons.contains(reason):
                return .turnInterrupted
            case let reason? where finishedReasons.contains(reason):
                return .turnFinished
            default:
                break
            }
            if let title, interruptedWordings.contains(title) {
                return .turnInterrupted
            }
            return .turnFinished
        default:
            return nil
        }
    }
}

// MARK: - Which of them the operator wants

/// The four switches, as one value.
///
/// Stored as the set that is *off* rather than the set that is on, and that is
/// the whole of the design: a kind this build has never heard of has no entry,
/// and an entry that is absent means "show it". Written the other way round, the
/// build that adds a fifth kind would ship it switched off on every phone that
/// had ever opened the settings screen -- which is a feature nobody would see and
/// nobody could explain.
public struct NotificationPreferences: Equatable, Sendable {
    /// The kinds that are switched off.
    private var off: Set<NotificationKind>

    /// Everything on. What a fresh install has.
    public static let allEnabled = NotificationPreferences()

    /// Build a preference set from the kinds that are off.
    /// - Parameter off: the kinds to suppress.
    public init(off: Set<NotificationKind> = []) {
        self.off = off
    }

    /// Whether a kind should be shown.
    /// - Parameter kind: the kind to ask about.
    /// - Returns: whether the operator wants it.
    public func isEnabled(_ kind: NotificationKind) -> Bool {
        !off.contains(kind)
    }

    /// Switch one kind on or off.
    /// - Parameters:
    ///   - enabled: whether to show it.
    ///   - kind: the kind to change.
    public mutating func set(_ enabled: Bool, for kind: NotificationKind) {
        if enabled { off.remove(kind) } else { off.insert(kind) }
    }

    /// The kinds currently suppressed, for a log line or a diagnosis.
    public var suppressed: Set<NotificationKind> { off }
}

extension NotificationPreferences: Codable {
    /// Written as one entry per kind, by name, rather than as the set of what is
    /// off.
    ///
    /// This is the file an operator reads when they are asking why a
    /// notification did not arrive, so it has to say `"question": false` rather
    /// than `{"off": ["question"]}` -- and a `true` per kind keeps a kind added
    /// in a later build visible as "on" instead of simply missing.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        for kind in NotificationKind.allCases {
            try container.encode(isEnabled(kind), forKey: Key(kind))
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        var off: Set<NotificationKind> = []
        for kind in NotificationKind.allCases {
            // Absent means on, the same rule as the storage: a kind this build's
            // archive reader has never seen must not read as switched off.
            if try container.decodeIfPresent(Bool.self, forKey: Key(kind)) == false {
                off.insert(kind)
            }
        }
        self.init(off: off)
    }

    /// The coding keys, one per kind.
    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }

        init(_ kind: NotificationKind) { stringValue = kind.rawValue }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
}

// MARK: - Where it is remembered

/// Somewhere a `Bool` can be kept.
///
/// A protocol and not `UserDefaults` directly, for the reason `CredentialStore`
/// is one: a test that has to write to the real defaults to check a default
/// value is a test that can only run on a machine that has them, and one that
/// leaves state behind for the next test to trip over.
///
/// Deliberately not `Sendable`. `UserDefaults` is not, and the app's settings
/// live on the main actor -- so the requirement would buy nothing and force an
/// `@unchecked` promise that nothing here can keep.
public protocol SettingsStorage {
    /// Read a stored flag.
    /// - Parameter key: the key.
    /// - Returns: the value, or `nil` when nothing has been stored.
    func bool(forKey key: String) -> Bool?

    /// Store a flag.
    /// - Parameters:
    ///   - value: the value.
    ///   - key: the key.
    func set(_ value: Bool, forKey key: String)

    /// Read a stored string.
    /// - Parameter key: the key.
    /// - Returns: the value, or `nil` when nothing has been stored.
    func string(forKey key: String) -> String?

    /// Store a string, or remove the entry when it is `nil`.
    /// - Parameters:
    ///   - value: the value.
    ///   - key: the key.
    func set(_ value: String?, forKey key: String)
}

/// `UserDefaults`, which is where the app's settings live.
///
/// Not the Keychain, and that is a decision rather than an oversight. A switch
/// position is not a secret, and the Keychain survives a reinstall -- which for
/// a preference means an app somebody reinstalled to get a clean slate comes
/// back with the notification switches they had forgotten about already off.
public struct UserDefaultsSettingsStorage: SettingsStorage {
    private let defaults: UserDefaults

    /// - Parameter defaults: the defaults to read and write.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func bool(forKey key: String) -> Bool? {
        // `object(forKey:)` rather than `bool(forKey:)`: the latter answers
        // `false` for a key that was never written, which is indistinguishable
        // from an operator switching something off -- and the difference is the
        // whole point of ``NotificationPreferences`` storing what is off.
        defaults.object(forKey: key) as? Bool
    }

    public func set(_ value: Bool, forKey key: String) {
        defaults.set(value, forKey: key)
    }

    public func string(forKey key: String) -> String? {
        defaults.string(forKey: key)
    }

    public func set(_ value: String?, forKey key: String) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}

// MARK: - The settings themselves

/// Everything the Settings screen can change.
public struct MizarSettings: Equatable, Sendable, Codable {
    /// Whether the Live Activity may be started and kept up to date. 实时活动.
    ///
    /// Read through ``AppModel/liveActivitiesEnabled`` in the app, which is the
    /// single place that feature consults. Not consulted here: this value
    /// describes the operator's wish, not whether the activity is on screen.
    public var liveActivitiesEnabled: Bool

    /// Which pushes to show.
    public var notifications: NotificationPreferences

    /// Whether this phone may use the computer's own address at all. 局域网优先.
    ///
    /// A rule rather than a preference, and the difference is the reported bug:
    /// this used to decide only whether a reconnect *probed* the local network
    /// first, while the stored direct address stayed first in the pairing and
    /// was dialled whatever the switch said. A phone debugged over a cable (a
    /// link-local address that reads as the LAN) therefore kept reconnecting
    /// over it with the switch off.
    ///
    /// Off, the direct route is not planned, not probed, and not dialled, and a
    /// link that is using it is closed the moment the switch moves. Reconnects
    /// then go straight to the relay, which is also why they are faster: there
    /// is no scan and no six-second direct timeout to wait out.
    ///
    /// On, every reconnect the operator can see asks the LAN question first:
    /// manual refresh, returning to the app, the Reconnect button, and the
    /// automatic failover after a local socket dies. A hit switches the pairing
    /// to the direct address -- which is what unlocks the LAN-only features and
    /// keeps traffic off the relay -- and a miss falls back to the relay, so
    /// turning this on can make a reconnect slower but never unable to connect.
    public var localNetworkFirst: Bool

    /// Whether a reconnect may try the punched direct path before the relay.
    /// 直连.
    ///
    /// Off by default, and off is a deliberate rollout decision rather than a
    /// conservative one. The punched route is the one route whose success
    /// depends on the network in the middle: two cone NATs meet in well under a
    /// second, a symmetric one never meets at all, and which of those a given
    /// carrier hands out is not something this app can find out without trying.
    /// Until there is a measured success rate, a switch means the people who
    /// turn it on are the ones who pay for a failed punch's few seconds — and
    /// everybody else keeps reconnecting exactly as fast as they do today.
    ///
    /// On, the route list gains `.p2p` between the direct address and the relay,
    /// so a failed punch falls through to the relay inside the same reconnect.
    /// The relay is not removed, ever: it is the route that works from networks
    /// where UDP does not leave at all.
    ///
    /// Off is equally absolute: no punch is attempted (the punch's own signaling
    /// rides the relay, so attempting one while off would still spend a round
    /// trip), and a link that is up over the punched route is closed when the
    /// switch moves.
    public var directConnection: Bool

    /// Whether a message sent into a running turn is handed over as guidance at
    /// once. 默认引导发送.
    ///
    /// On, the prompt travels with `mode: "steer"`: the host feeds it to the
    /// model as it stands, inside the turn that is already running, and nothing
    /// is interrupted.
    ///
    /// Off -- the default -- the prompt does not leave the phone while a turn is
    /// running. It is held in a bar above the field, where it can still be sent
    /// as guidance by hand, put back in the field, or thrown away, and it is
    /// handed to the host once the running turn has ended. The holding is the
    /// phone's, not the host's queue: a message already queued at the host could
    /// not be called back, and calling it back is the whole point of the bar.
    ///
    /// The switch changes the ordinary send. A prompt carrying attachments is
    /// always handed over at once -- its files are already on the host by the
    /// time the text is -- and is queued unless this is on.
    public var guidedSendByDefault: Bool

    /// Which relay this phone uses: the official one, or the operator's own.
    ///
    /// Kept here with the other choices so the guide, the settings page and the
    /// relay tier all read one value. It decides much more than an address:
    /// accounts, plans and push are official-only, and a self-hosted relay is
    /// addressed by ``selfHostedOrigin`` instead of the built-in relay URLs.
    public var serverMode: ServerMode

    /// The self-hosted relay's origin, as the operator entered it.
    ///
    /// Stored unnormalised so the settings field shows what they typed; the
    /// form that is dialled is ``ServerSelection/normalizedOrigin``.
    public var selfHostedOrigin: String

    /// The self-hosted relay's PIN, empty when it does not require one.
    public var selfHostedPin: String

    /// Everything at its default: notifications on, live activity on, the local
    /// network looked for only when the operator asks for it, the punched
    /// route off until it has a success rate, a send into a running turn
    /// held for the end of that turn, and the official server.
    public init(
        liveActivitiesEnabled: Bool = true,
        notifications: NotificationPreferences = .allEnabled,
        localNetworkFirst: Bool = false,
        directConnection: Bool = false,
        guidedSendByDefault: Bool = false,
        serverMode: ServerMode = .official,
        selfHostedOrigin: String = "",
        selfHostedPin: String = "",
    ) {
        self.liveActivitiesEnabled = liveActivitiesEnabled
        self.notifications = notifications
        self.localNetworkFirst = localNetworkFirst
        self.directConnection = directConnection
        self.guidedSendByDefault = guidedSendByDefault
        self.serverMode = serverMode
        self.selfHostedOrigin = selfHostedOrigin
        self.selfHostedPin = selfHostedPin
    }

    /// The server choice as one value.
    ///
    /// The three fields are stored separately because two of them are a form
    /// somebody is halfway through typing (an origin with no PIN yet). This is
    /// the read the model and the verification use.
    public var serverSelection: ServerSelection {
        get {
            ServerSelection(
                mode: serverMode,
                origin: selfHostedOrigin,
                pin: selfHostedPin,
            )
        }
        set {
            serverMode = newValue.mode
            // Trimmed at the one place a whole selection is written: the form
            // fields can hold a trailing space while somebody is typing, and a
            // stored value is read back by another process.
            selfHostedOrigin = newValue.origin.trimmingCharacters(in: .whitespacesAndNewlines)
            selfHostedPin = newValue.pin.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    /// The key the live activity switch is stored under.
    public static let liveActivitiesKey = "mizar.settings.liveActivity"

    /// The key the LAN-priority switch is stored under.
    public static let localNetworkFirstKey = "mizar.settings.localNetworkFirst"

    /// The key the direct-connection switch is stored under.
    public static let directConnectionKey = "mizar.settings.directConnection"

    /// The key the guided-send switch is stored under.
    public static let guidedSendKey = "mizar.settings.guidedSend"

    /// The key the official/self-hosted choice is stored under.
    public static let serverModeKey = "mizar.settings.serverMode"

    /// The key the self-hosted origin is stored under.
    public static let selfHostedOriginKey = "mizar.settings.selfHostedOrigin"

    /// The key the self-hosted server PIN is stored under.
    public static let selfHostedPinKey = "mizar.settings.selfHostedPin"

    /// The key one notification kind is stored under.
    /// - Parameter kind: the kind.
    /// - Returns: the storage key.
    public static func notificationsKey(_ kind: NotificationKind) -> String {
        "mizar.settings.notify.\(kind.rawValue)"
    }

    /// Read the settings as they were last written.
    ///
    /// Every read has a default, so a first launch -- and a storage that has
    /// been cleared -- produce a working app rather than four switches in an
    /// unknown state.
    ///
    /// - Parameter storage: where to read from.
    /// - Returns: the settings.
    public static func load(from storage: some SettingsStorage) -> MizarSettings {
        var notifications = NotificationPreferences()
        for kind in NotificationKind.allCases {
            // Only an explicit `false` switches something off. See
            // ``NotificationPreferences``: absent means on.
            if storage.bool(forKey: notificationsKey(kind)) == false {
                notifications.set(false, for: kind)
            }
        }
        return MizarSettings(
            // Stored as the switch itself, so it reads the same way round as the
            // screen it is drawn on: on by default, and `false` means the
            // operator turned it off.
            liveActivitiesEnabled: storage.bool(forKey: liveActivitiesKey) ?? true,
            notifications: notifications,
            // Off by default: the scan is a cost the operator opts into, and a
            // fresh install should reconnect as fast as it can.
            localNetworkFirst: storage.bool(forKey: localNetworkFirstKey) ?? false,
            // Off by default: see ``directConnection``.
            directConnection: storage.bool(forKey: directConnectionKey) ?? false,
            // Off by default: the host's queue has been the behaviour so far,
            // and guidance into a running turn is a change the operator asks
            // for. See ``guidedSendByDefault``.
            guidedSendByDefault: storage.bool(forKey: guidedSendKey) ?? false,
            // Official by default: the official path is the one that existed
            // before this field, and a default read must not change it.
            serverMode: ServerMode(rawValue: storage.string(forKey: serverModeKey) ?? "") ?? .official,
            // A stored origin is trimmed on the way in. Normalisation (scheme,
            // trailing slash) happens where it is dialled, so the settings field
            // keeps showing what the operator typed.
            selfHostedOrigin: (storage.string(forKey: selfHostedOriginKey) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines),
            selfHostedPin: (storage.string(forKey: selfHostedPinKey) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines),
        )
    }

    /// Write the settings down.
    /// - Parameter storage: where to write.
    public func save(to storage: some SettingsStorage) {
        storage.set(liveActivitiesEnabled, forKey: Self.liveActivitiesKey)
        storage.set(localNetworkFirst, forKey: Self.localNetworkFirstKey)
        storage.set(directConnection, forKey: Self.directConnectionKey)
        storage.set(guidedSendByDefault, forKey: Self.guidedSendKey)
        storage.set(serverMode.rawValue, forKey: Self.serverModeKey)
        storage.set(selfHostedOrigin, forKey: Self.selfHostedOriginKey)
        storage.set(selfHostedPin, forKey: Self.selfHostedPinKey)
        for kind in NotificationKind.allCases {
            storage.set(notifications.isEnabled(kind), forKey: Self.notificationsKey(kind))
        }
    }
}
