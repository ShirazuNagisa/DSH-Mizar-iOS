//
//  DomainModels.swift
//  MizarKit
//
//  Typed views of what the host reports.
//
//  Every optional here mirrors an optional on the host, and the host's rule is
//  the important part: **an absent projection key means the capability is not
//  composed, not that its value is zero.** A token count of `nil` must render as
//  "unknown"; rendering it as `0` would be a lie an operator could act on. So
//  optionals are preserved all the way to the view layer rather than being
//  defaulted here.
//

import Foundation

// MARK: - Host

/// Host identity and protocol facts.
public struct HostInfo: Decodable, Sendable, Equatable {
    public let hostId: String
    public let hostName: String
    /// The host's DSH home directory.
    public let home: String
    public let protocolVersion: Int
    /// Every `host:port` the host's own listener is bound to, when the host
    /// says. Optional because it is a later addition to the frame: a host from
    /// before it answers the rest of `host.info` and no `addresses` at all, and
    /// a phone must fall back to the one address its pairing already knows
    /// rather than reading "the host cannot say" as "the host has no LAN
    /// address".
    ///
    /// This is what makes a LAN scan possible while the phone is connected
    /// through the relay: the computer answers over the relay with the
    /// addresses it is listening on, and the phone probes those directly.
    public let addresses: [String]?

    /// Where this host's relay tunnel currently points, when the host can move
    /// between the two public relays.
    ///
    /// Optional for the same reason as `addresses`: an older host answers
    /// without it, and the phone must read "cannot say" rather than "no relay".
    /// `baseURL` is `nil` until the tunnel has a room.
    public let relay: HostRelay?
    /// Explicit plugin identity and optional capabilities; absent on older hosts.
    public let plugin: HostPlugin?

    /// What this computer is: its operating system and desktop product.
    ///
    /// Optional because it is a later addition to `host.info`: an older host
    /// answers without it, and the phone must keep showing the name it already
    /// holds rather than inventing an OS. The pairing record stores the value
    /// once a host has said it, so the computer list can draw it while offline.
    public let desktop: HostDesktop?

    /// The host's direct-path identity, when its engine is running.
    ///
    /// The public half of the key a punched connection is authenticated by. The
    /// host derives it from the tunnel secret it already holds, so this is not a
    /// new credential and it survives a reinstall; it is absent when the host
    /// predates the direct path or when its engine did not start, which are the
    /// same thing from here.
    ///
    /// Optional for the third time in this struct, for the third time for the
    /// same reason: an app must read "cannot say" rather than "no direct path".
    public let netEndpointId: String?

    /// Every agent this computer serves, when it hosts more than one.
    ///
    /// A desktop can front DSH, Claude Code and Codex at the same time, and the
    /// three share nothing. This is how the phone knows to ask which one, rather
    /// than drawing one merged list and calling it "this computer". Absent when
    /// the host is older than the field, which reads exactly like a computer
    /// with one agent, and neither is a reason to show a picker.
    public let engines: [HostEngine]?

    /// Which agent *this connection* is bound to, when it is bound to one.
    ///
    /// The computer's own answer, not the phone's choice repeated back: a token
    /// the relay minted is scoped on the computer's side, so this is the only
    /// authority on what the list that arrives can contain. `nil` means no scope
    /// at all -- all three agents, which is what every connection did before the
    /// choice existed.
    public let engine: String?

    public init(
        hostId: String,
        hostName: String,
        home: String,
        protocolVersion: Int,
        addresses: [String]? = nil,
        relay: HostRelay? = nil,
        plugin: HostPlugin? = nil,
        desktop: HostDesktop? = nil,
        netEndpointId: String? = nil,
        engines: [HostEngine]? = nil,
        engine: String? = nil,
    ) {
        self.hostId = hostId
        self.hostName = hostName
        self.home = home
        self.protocolVersion = protocolVersion
        self.addresses = addresses
        self.relay = relay
        self.plugin = plugin
        self.desktop = desktop
        self.netEndpointId = netEndpointId
        self.engines = engines
        self.engine = engine
    }
}

/// One agent a computer serves, as `host.info` lists it.
public struct HostEngine: Codable, Sendable, Equatable, Identifiable {
    /// The wire name, which is also the prefix of every session id it owns:
    /// `dsh`, `claude`, `codex`.
    public let id: String
    /// The product's display name, for a picker row.
    public let label: String?
    /// Whether the agent is reachable right now.
    public let connected: Bool?
    /// Why it is not, when the host says.
    public let detail: String?

    public init(id: String, label: String? = nil, connected: Bool? = nil, detail: String? = nil) {
        self.id = id
        self.label = label
        self.connected = connected
        self.detail = detail
    }
}

/// What a computer is, as `host.info` reports it.
///
/// The strings are display names, not enums: `macOS`/`Windows`/`Linux` for the
/// OS and `DSH`/`Codex`/`Claude Code` for the desktop product. A new product is
/// therefore a new string, not a protocol version; the app draws any short name
/// it is given. `labels` fixes the order the computer list uses (system first,
/// product second) and drops blanks so a partial answer cannot draw an empty
/// capsule.
public struct HostDesktop: Codable, Sendable, Equatable {
    /// The operating system's display name.
    public let os: String
    /// The desktop product's display name.
    public let client: String

    public init(os: String, client: String) {
        self.os = os
        self.client = client
    }

    /// The non-empty labels to draw, OS first, product second.
    public var labels: [String] {
        [os, client]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    /// Whether this answer carries anything worth drawing.
    public var isEmpty: Bool { labels.isEmpty }
}

/// Where a host's relay tunnel points, as `host.info` reports it.
public struct HostRelay: Decodable, Sendable, Equatable {
    /// The relay origin the host dials.
    public let url: String
    /// The room the relay assigned, once connected.
    public let room: String?
    /// The base URL a phone should dial (origin plus `/r/<room>`), or `nil`
    /// before the tunnel has a room.
    public let baseURL: String?

    public init(url: String, room: String?, baseURL: String?) {
        self.url = url
        self.room = room
        self.baseURL = baseURL
    }
}

/// The answer to asking a host to move its tunnel to another relay.
public struct RelaySetResult: Decodable, Sendable, Equatable {
    /// The relay origin the host will dial.
    public let url: String
    /// The room, unchanged by the move.
    public let room: String?
    /// The base URL a phone should dial after the move.
    public let baseURL: String?

    public init(url: String, room: String?, baseURL: String?) {
        self.url = url
        self.room = room
        self.baseURL = baseURL
    }
}

// MARK: - Sessions

/// The session list.
public struct SessionListResult: Decodable, Sendable, Equatable {
    public let items: [SessionRow]
}

/// The workspaces DSH has.
///
/// `complete` is the difference between two identical-looking answers. A host
/// that read its registry and found nothing and a host that could not read it at
/// all both send an empty array, and only one of them is grounds for taking a
/// workspace off the operator's screen. Absent means "not complete": a host
/// older than the registry read cannot say, and a phone must not throw away what
/// it has on the strength of a field nobody sent.
public struct WorkspaceListResult: Decodable, Sendable, Equatable {
    public let items: [WorkspaceRow]
    public let complete: Bool

    private enum CodingKeys: String, CodingKey {
        case items
        case complete
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = try container.decodeIfPresent([WorkspaceRow].self, forKey: .items) ?? []
        complete = try container.decodeIfPresent(Bool.self, forKey: .complete) ?? false
    }

    public init(items: [WorkspaceRow], complete: Bool) {
        self.items = items
        self.complete = complete
    }
}

/// One workspace, as the host reports it.
///
/// The phone needs the path, what DSH calls it, and — crucially — which sessions
/// DSH has filed under it. Membership is not something the phone can work out
/// for itself: a session created with a bare directory is in no workspace at
/// all, and a workspace's list is membership rather than a directory scan. It is
/// also the difference between one directory and two spellings of it, which on
/// macOS is `/tmp/x` against `/private/tmp/x`.
public struct WorkspaceRow: Codable, Sendable, Equatable, Identifiable {
    public let workspaceId: String
    /// The directory the workspace is rooted at, as DSH canonicalised it.
    public let path: String
    /// What DSH calls it.
    public let title: String
    /// The sessions DSH has filed under it, in DSH's order, or `nil` when the
    /// host did not say.
    ///
    /// Optional on purpose, and the difference is load-bearing: an empty list is
    /// DSH saying nothing is filed here, and `nil` is DSH saying nothing at all
    /// — which is the older host, and the only case where the phone falls back
    /// to matching a session's directory against the workspace path.
    public let sessionIds: [String]?

    /// Which agent owns this folder, when the host says.
    ///
    /// A computer that fronts three agents sends rows for all of them on an
    /// unscoped connection (`dsh:…`, `claude:…`, `codex:…` ids), and a phone
    /// that cannot tell them apart draws Codex's folders under DSH's. The id
    /// carries the same information, so this field is only a second spelling of
    /// it -- `nil` for a host that fronts one agent, and for the on-device
    /// kernel, which sends bare ids.
    public let engine: String?

    public var id: String { workspaceId }

    public init(
        workspaceId: String,
        path: String,
        title: String,
        sessionIds: [String]? = nil,
        engine: String? = nil,
    ) {
        self.workspaceId = workspaceId
        self.path = path
        self.title = title
        self.sessionIds = sessionIds
        self.engine = engine
    }

    /// Decoded leniently, because this is also what a stored index is read with.
    ///
    /// An index written before the host sent membership decodes with none rather
    /// than failing, which matters: a stored index that will not decode is a
    /// session list with no rows in it.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        workspaceId = try container.decode(String.self, forKey: .workspaceId)
        path = try container.decode(String.self, forKey: .path)
        let decoded = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        // An empty title is not a name. DSH's own list would show the directory,
        // and a heading with nothing in it is a section nobody can identify.
        title = decoded.isEmpty ? path : decoded
        // `try?` on purpose: a membership list of the wrong shape is not worth
        // an index that will not load, and "the host did not say" is the answer
        // that hides nothing -- the phone still matches sessions on the path.
        sessionIds = (try? container.decodeIfPresent([String].self, forKey: .sessionIds)) ?? nil
        engine = (try? container.decodeIfPresent(String.self, forKey: .engine)) ?? nil
    }

    private enum CodingKeys: String, CodingKey {
        case workspaceId
        case path
        case title
        case sessionIds
        case engine
    }
}

/// The `{ workspace: … }` envelope `workspace.create` answers with.
///
/// A kernel extension: the desktop host makes a workspace by being asked to
/// start a session in a directory that already exists. A host that owns its
/// root -- the on-device agent -- can be asked to make the folder.
public struct WorkspaceCreateResult: Decodable, Sendable, Equatable {
    public let workspace: WorkspaceRow
}

/// One row in the session list.
///
/// `Codable`, not merely `Decodable`, because the list is kept on the phone:
/// `session/list` needs a round trip to a machine that may be asleep, and a
/// screen that can only draw rows while the network is up is a screen that is
/// empty exactly when the operator wants to know what their agent is doing.
public struct SessionRow: Codable, Sendable, Equatable, Identifiable {
    public let sessionId: String
    /// Last activity, epoch milliseconds.
    public let updatedAt: Double
    /// Whether a turn is currently executing.
    public let running: Bool
    /// Whether the session has no user prompt yet.
    public let blank: Bool
    /// Whether an agent can be resolved for it.
    public let agentAvailable: Bool
    public let cwd: String?
    /// The session this one was forked from, when it has one.
    ///
    /// **Not a subagent marker.** DSH's "branch in a new conversation" copies a
    /// turn's history into a new session whose header carries its source as
    /// `parentSession` (this field) with no `origin` -- a real header from this
    /// machine: `parentSession: session-31e3…`, `isSeeded: true`, no origin. That
    /// is an ordinary conversation the operator asked for, and treating it as a
    /// delegated child is what kept forked conversations off the phone entirely.
    /// Subagents are marked by ``origin``, the host's own classification.
    public let parentSessionId: String?
    /// `"subagent"` for delegated children, exactly as the host classifies them.
    public let origin: String?

    public var id: String { sessionId }

    public init(
        sessionId: String,
        updatedAt: Double,
        running: Bool,
        blank: Bool,
        agentAvailable: Bool,
        cwd: String?,
        parentSessionId: String? = nil,
        origin: String? = nil,
    ) {
        self.sessionId = sessionId
        self.updatedAt = updatedAt
        self.running = running
        self.blank = blank
        self.agentAvailable = agentAvailable
        self.cwd = cwd
        self.parentSessionId = parentSessionId
        self.origin = origin
    }

    /// Last activity as a date.
    public var updatedDate: Date { Date(timeIntervalSince1970: updatedAt / 1000) }

    /// Whether this row is a delegated child session.
    ///
    /// The host's `origin` is the classification, and it is the only one: a
    /// session created by the agent to do part of the work carries
    /// `origin: "subagent"` (and a parent, and a delegation depth > 0). A fork
    /// made by "branch in a new conversation" carries the parent without the
    /// origin, because it is the operator's conversation, not the agent's
    /// bookkeeping. Honouring `parentSessionId` here as well -- which the app
    /// used to do, on the belief that the two marks meant the same thing --
    /// hid every forked conversation from the list, the history sync and the
    /// Live Activity.
    public var isSubagent: Bool { origin == "subagent" }

    /// Whether this row was forked from another session.
    ///
    /// A fork is a top-level conversation: it is drawn, synced and allowed on
    /// the island like any other. This property exists so the distinction can be
    /// named where it matters rather than re-derived from the two fields.
    public var isFork: Bool { parentSessionId != nil && !isSubagent }

    /// Whether this row is a delegated child of the named session.
    ///
    /// The session list is the only census of delegated work: a conversation's
    /// turns carry no subagent mark, and the host does not address a child as a
    /// session for the ordinary reads. The count on the drawer's Subagents
    /// segment and the rows on its page therefore come from this one predicate.
    ///
    /// A nil session is never a match, deliberately. The drawer's plane stays
    /// mounted while no conversation is open, and a row with no parent must not
    /// be counted as somebody's child.
    ///
    /// - Parameter sessionId: the parent conversation, or `nil` when none is open.
    /// - Returns: whether this row is its delegated child.
    public func isSubagent(of sessionId: String?) -> Bool {
        guard let sessionId, isSubagent else { return false }
        return parentSessionId == sessionId
    }
}

// MARK: - Usage

/// One session's usage frame.
public struct SessionStatsResult: Decodable, Sendable, Equatable {
    public let sessionId: String
    /// The log cursor the frame reflects; `nil` when the session is unknown.
    public let asOfSeq: Double?
    /// `nil` when the token meter is not composed — not a zeroed stand-in.
    public let stats: SessionStatsFrame?
}

/// Everything the usage screen renders.
///
/// Every field is optional because the host reads each of them from a separate
/// projection, and a projection answers with what it has *right now*: a session
/// whose agent is cold has no model selection and no context pressure, and a
/// title only exists once a model has read the conversation. A frame carrying
/// less than the last one is therefore the ordinary case rather than a failure
/// — which is why one is merged into the last rather than replacing it.
public struct SessionStatsFrame: Codable, Sendable, Equatable {
    public let tokenUsage: TokenUsage?
    public let cacheHit: CacheHit?
    public let context: ContextPressure?
    public let stats: Throughput?
    public let model: ModelSelectionPair?
    public let permissionPreset: String?
    public let title: String?

    /// This frame's fields, over another's.
    ///
    /// A field the newer frame does not carry keeps the value it had. That is
    /// the rule the whole app is built on — a screen that has an answer and
    /// loses it is worse than one that never had it — applied to the frame
    /// rather than to the screen.
    ///
    /// Reported from the phone as the figures *vanishing* on the way into a
    /// session: "刚点进去一个会话，然后该会话的标题、正在使用的模型、上下文用量
    /// 显示全部消失，解决办法是尝试重新进入会话". The stored frame drew them and
    /// the host's answer replaced it a moment later — and an answer from a cold
    /// session is a frame with no title, no model and no context pressure,
    /// because none of those projections has anything to say until the agent has
    /// run. Merging is what makes the second read an improvement on the first
    /// rather than a coin toss.
    ///
    /// Nested values are taken whole rather than merged field by field: a
    /// projection the host did answer with is a better answer than a mixture of
    /// two reads taken at different moments, and `context.percent` is computed
    /// from the tokens beside it.
    ///
    /// - Parameter previous: the last frame the phone had, or `nil`.
    /// - Returns: the frame to keep.
    public func merging(_ previous: SessionStatsFrame?) -> SessionStatsFrame {
        guard let previous else { return self }
        return SessionStatsFrame(
            tokenUsage: tokenUsage ?? previous.tokenUsage,
            cacheHit: cacheHit ?? previous.cacheHit,
            context: context ?? previous.context,
            stats: stats ?? previous.stats,
            model: model ?? previous.model,
            // The two that are names rather than numbers: an empty one is not a
            // name, and it is what a projection answers with while it is still
            // working something out. Showing it would blank the navigation
            // title, which is the same loss by another route.
            permissionPreset: Self.named(permissionPreset, previous.permissionPreset),
            title: Self.named(title, previous.title),
        )
    }

    /// The newer of two names, treating an empty one as absent.
    ///
    /// - Parameters:
    ///   - fresh: the name from the frame just read.
    ///   - previous: the name from the frame before it.
    /// - Returns: the name to keep.
    private static func named(_ fresh: String?, _ previous: String?) -> String? {
        guard let fresh, !fresh.isEmpty else { return previous }
        return fresh
    }

    public init(
        tokenUsage: TokenUsage? = nil,
        cacheHit: CacheHit? = nil,
        context: ContextPressure? = nil,
        stats: Throughput? = nil,
        model: ModelSelectionPair? = nil,
        permissionPreset: String? = nil,
        title: String? = nil,
    ) {
        self.tokenUsage = tokenUsage
        self.cacheHit = cacheHit
        self.context = context
        self.stats = stats
        self.model = model
        self.permissionPreset = permissionPreset
        self.title = title
    }

    /// Whether this frame has nothing to say.
    ///
    /// A session nobody has run yet answers with a frame shaped exactly like a
    /// cold one, and "no answer" and "an empty answer" are different things to
    /// the screen deciding what to draw.
    public var isEmpty: Bool {
        tokenUsage == nil && cacheHit == nil && context == nil && stats == nil
            && model == nil && permissionPreset == nil && title == nil
    }
}

/// Cumulative billed tokens over the whole durable log.
public struct TokenUsage: Codable, Sendable, Equatable {
    public let uncachedInputTokens: Int
    public let outputTokens: Int
    public let cacheReadTokens: Int
    public let cacheWriteTokens: Int
    /// `uncachedInputTokens + cacheReadTokens + cacheWriteTokens`.
    public let billedInputTokens: Int
}

/// Cache effectiveness, computed host-side.
public struct CacheHit: Codable, Sendable, Equatable {
    /// Exact ratio in `[0, 1]`, or `nil` when nothing has been billed.
    public let ratio: Double?
    /// Display-ready percentage that never overstates the saving.
    ///
    /// A string rather than a number because "99.96% rounds to 100%" is exactly
    /// the claim a cache report must not make; the host picks the precision and
    /// the app must not re-round it.
    public let displayPercent: String?
}

/// Context-window occupancy.
public struct ContextPressure: Codable, Sendable, Equatable {
    public let window: Int?
    public let pressureTokens: Int?
    public let projectedTokens: Int?
    /// Occupancy percentage, clamped to 100, or `nil` when uncomputable.
    public let percent: Int?
    /// Approximate composition; never sums to `projectedTokens`.
    public let breakdown: ContextBreakdown?
}

/// Approximate composition of the context.
public struct ContextBreakdown: Codable, Sendable, Equatable {
    public let systemTokens: Int
    public let toolsTokens: Int
    public let messageTokens: Int
}

/// Latency and throughput folded from the durable log.
public struct Throughput: Codable, Sendable, Equatable {
    public let turns: Int
    public let steps: Int
    public let llmMs: Double
    public let toolMs: Double
    /// Time to first token, averaged over the steps that reported one.
    public let ttftMs: Double?
    public let decodeTokensPerSecond: Double?
}

/// The route the last request used, and any pending change.
public struct ModelSelectionPair: Codable, Sendable, Equatable {
    public let lastUsed: ModelSelection?
    public let next: ModelSelection?

    /// Build a pair rather than only decoding one, so a caller that already
    /// knows the route (the phone's own accepted switch) can say so.
    /// - Parameters:
    ///   - lastUsed: the route the last request used.
    ///   - next: the pending change for the next request.
    public init(lastUsed: ModelSelection? = nil, next: ModelSelection? = nil) {
        self.lastUsed = lastUsed
        self.next = next
    }
}

/// A provider, model and optional reasoning effort.
public struct ModelSelection: Codable, Sendable, Equatable, Hashable {
    public let provider: String
    public let model: String
    public let reasoningEffort: String?

    /// Build a selection from the parts the app holds. Decoding is the other
    /// way in; a route the phone chose itself never comes off the wire.
    /// - Parameters:
    ///   - provider: the provider id.
    ///   - model: the model id.
    ///   - reasoningEffort: the reasoning level, or `nil` for the provider default.
    public init(provider: String, model: String, reasoningEffort: String? = nil) {
        self.provider = provider
        self.model = model
        self.reasoningEffort = reasoningEffort
    }
}

// MARK: - Model catalog

/// The model catalog the picker renders.
public struct ModelCatalog: Decodable, Sendable, Equatable {
    /// The route a new session would use.
    public let defaultSelection: ModelSelection?
    public let providers: [ProviderGroup]
    /// Providers that failed to enumerate; shown rather than hidden.
    public let failures: [CatalogFailure]

    private enum CodingKeys: String, CodingKey {
        // `default` is a Swift keyword; the wire name is kept via CodingKeys.
        case defaultSelection = "default"
        case providers
        case failures
    }
}

/// One provider and its models.
public struct ProviderGroup: Decodable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let models: [ModelOption]
}

/// One selectable model.
public struct ModelOption: Decodable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let description: String?
    /// The reasoning levels this model accepts, in the provider's order.
    ///
    /// Empty means the model takes no `reasoningEffort`; sending one is a hard
    /// error upstream rather than something that gets clamped, so the picker
    /// must not offer one.
    public let efforts: [ReasoningEffortOption]
    /// The level the provider applies when none is chosen.
    public let defaultEffort: String?
}

/// One reasoning level.
public struct ReasoningEffortOption: Decodable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let description: String?
}

/// A provider that could not be listed.
public struct CatalogFailure: Decodable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let message: String
}

/// The outcome of selecting a model for a session.
public struct SelectModelResult: Decodable, Sendable, Equatable {
    public let sessionId: String
    public let selected: ModelSelection
}

// MARK: - Permissions

/// The permission presets this host currently offers.
public struct PermissionCatalog: Decodable, Sendable, Equatable {
    /// Presets a session may be switched to.
    public let options: [PermissionOption]
    /// Presets offered for future sessions' default.
    public let defaults: [PermissionOption]
    /// The preset a new session would use.
    public let defaultPreset: String
}

/// One selectable preset.
public struct PermissionOption: Decodable, Sendable, Equatable, Identifiable {
    /// The preset id passed back when switching.
    public let value: String
    public let name: String
    public let description: String?

    public var id: String { value }

    /// Whether this preset grants unrestricted filesystem and network access.
    ///
    /// The UI asks for a second confirmation before switching to it. `auto` is
    /// deliberately not treated as dangerous here: it is a live-only preset with
    /// its own review integration, not a blanket grant.
    public var isDangerous: Bool { value == "danger-full-access" }
}

// MARK: - Interactions

/// Everything waiting on the operator right now.
public struct PendingInteractions: Decodable, Sendable, Equatable {
    public let approvals: [PendingApproval]
    public let questions: [PendingQuestion]

    /// Whether anything needs the operator's attention.
    public var isEmpty: Bool { approvals.isEmpty && questions.isEmpty }
}

/// An approval awaiting a decision.
public struct PendingApproval: Decodable, Sendable, Equatable, Identifiable {
    public let requestId: String
    public let sessionId: String?
    public let toolName: String
    public let callId: String?
    public let reason: String?
    /// Localized presentation text, when the requesting tool supplied one.
    public let displayReason: [String: String]?
    public let requestedAt: Double

    public var id: String { requestId }

    /// The best text to show for why the action needs approval.
    ///
    /// - Parameter preferredLocale: the locale to prefer.
    /// - Returns: the localized text when present, else the raw reason.
    public func reasonText(preferring preferredLocale: String) -> String? {
        if let displayReason {
            let language = String(preferredLocale.prefix(2))
            if let match = displayReason[language] { return match }
            if let fallback = displayReason["en"] { return fallback }
        }
        return reason
    }
}

/// Outcomes the operator may choose for an approval.
public enum ApprovalOutcome: String, Sendable, CaseIterable {
    /// Grants the action once. The only outcome that grants anything.
    case allowedOnce = "allowed-once"
    case rejected
}

/// A question batch awaiting answers.
public struct PendingQuestion: Decodable, Sendable, Equatable, Identifiable {
    public let callId: String
    public let sessionId: String?
    public let questions: [QuestionItem]
    public let requestedAt: Double

    public var id: String { callId }
}

/// One question in a batch.
public struct QuestionItem: Decodable, Sendable, Equatable, Identifiable {
    public let id: String
    public let question: String
    public let detail: String?
    public let header: String?
    public let options: [QuestionOption]
    public let multiSelect: Bool
    /// Set when the question is a plan awaiting approval.
    public let intent: QuestionIntent?
}

/// One answerable option.
public struct QuestionOption: Decodable, Sendable, Equatable {
    public let label: String
    public let description: String?
}

/// A plan review, which is answered like any other question.
public struct QuestionIntent: Decodable, Sendable, Equatable {
    public let kind: String
    /// The label that approves the plan.
    public let approve: String

    public var isPlanReview: Bool { kind == "plan-review" }
}

/// The operator's answer to one question.
public struct QuestionAnswer: Codable, Sendable, Equatable {
    public let id: String
    public let selected: [String]
    public let custom: String?

    public init(id: String, selected: [String], custom: String? = nil) {
        self.id = id
        self.selected = selected
        self.custom = custom
    }
}

/// A batch of answers, one per question.
public struct QuestionAnswerBatch: Codable, Sendable, Equatable {
    public let answers: [QuestionAnswer]

    public init(answers: [QuestionAnswer]) {
        self.answers = answers
    }
}

/// The host's answer to a push registration.
///
/// `registered` is false when the machine has no push at all -- no relay, or a
/// relay that does not carry notifications. Reported rather than thrown, so a
/// client that meets it has nothing to retry: the answer will be the same next
/// time, and the app works without notifications.
public struct PushRegistrationResult: Decodable, Sendable, Equatable {
    public let registered: Bool
}

/// The host's answer to forgetting a push registration.
///
/// Its own type rather than reusing ``AcceptanceResult``: the two methods answer
/// different fields, and decoding the wrong one turns a reply that cannot be read
/// into a silent `try?` that no future change can detect breaking.
public struct PushUnregisterResult: Decodable, Sendable, Equatable {
    public let unregistered: Bool
}

/// An acceptance response that carries only a flag.
public struct AcceptanceResult: Decodable, Sendable, Equatable {
    public let accepted: Bool
}

/// A newly created or resumed session.
public struct CreateSessionResult: Decodable, Sendable, Equatable {
    public let sessionId: String
    public let agentPreset: String?
}

/// The acceptance of a prompt, with the idempotency key the host recorded.
public struct PromptResult: Decodable, Sendable, Equatable {
    public let accepted: Bool
    public let requestId: String
}

/// How a prompt reaches a host that is already running a turn.
///
/// The wire calls this field `mode`, and the two values are the host's own
/// (`dsh/src/bridge/sessions.ts`): ``queue`` is the old behaviour -- the host
/// starts the prompt once the current turn ends -- and ``steer`` feeds it to the
/// model inside the turn that is running, without interrupting anything.
///
/// Omitted rather than spelled out for ``queue``: a host older than the field
/// defaults to it, and a client that always sent the default would make every
/// ordinary send depend on a newer plugin. Known older hosts (this repository's
/// `LocalKernel` among them) accept `steer` and treat it as `queue`, which is a
/// queue rather than an error and the right degradation.
public enum PromptMode: String, Sendable, Codable, CaseIterable {
    /// Start it when the running turn ends.
    case queue
    /// Hand it to the running turn as guidance.
    case steer

    /// Whether the field has to travel on the wire.
    ///
    /// False for ``queue``: see the note above about older hosts.
    public var isExplicitOnTheWire: Bool { self == .steer }
}

/// The host's report on a permission switch.
public struct SetPermissionResult: Decodable, Sendable, Equatable {
    public let commandResult: CommandResult

    public struct CommandResult: Decodable, Sendable, Equatable {
        public let kind: String
        public let text: String?

        public var succeeded: Bool { kind == "success" }
    }
}
