import Foundation
import Observation

/// An explicit plugin capability, not an inference from a session's selected model.
public struct HostPlugin: Decodable, Sendable, Equatable {
    public let id: String
    public let capabilities: [String]

    public init(id: String, capabilities: [String]) {
        self.id = id
        self.capabilities = capabilities
    }

    public var supportsDeepSeekBalance: Bool {
        id == "dsh-mizar" && capabilities.contains("deepseek.balance.v1")
    }
}

/// Monetary strings stay lossless: no floating-point conversion or default zero.
public struct DeepSeekWallet: Decodable, Sendable, Equatable {
    public let currency: String
    public let balance: String

    public init(currency: String, balance: String) throws {
        guard ["CNY", "USD"].contains(currency),
              balance.count <= 256,
              balance.range(of: #"^-?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?\z"#, options: .regularExpression) != nil
        else { throw DeepSeekBalanceValidation.invalidWallet }
        self.currency = currency
        self.balance = balance
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(currency: values.decode(String.self, forKey: .currency), balance: values.decode(String.self, forKey: .balance))
    }

    private enum CodingKeys: String, CodingKey { case currency, balance }
}

public enum DeepSeekBalanceValidation: Error { case invalidWallet, invalidResponse }

public struct DeepSeekBalance: Sendable, Equatable {
    public let wallets: [DeepSeekWallet]
    public let bonusWallets: [DeepSeekWallet]
    public static let topUpURL = URL(string: "https://platform.deepseek.com/top_up")!
}

/// Only allow the official top-up page, with no credentials or redirect parameters.
public func isOfficialDeepSeekTopUpURL(_ value: String) -> Bool {
    guard let url = URLComponents(string: value) else { return false }
    return url.scheme == "https" && url.host == "platform.deepseek.com"
        && url.port == nil && url.user == nil && url.password == nil
        && url.path == "/top_up" && url.query == nil && url.fragment == nil
}

public enum DeepSeekBalanceResponse: Decodable, Sendable, Equatable {
    case unsupported, signedOut, unavailable
    case ready(DeepSeekBalance)

    private enum CodingKeys: String, CodingKey { case status, wallets, bonusWallets, topUpURL }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(String.self, forKey: .status) {
        case "unsupported": self = .unsupported
        case "signed-out": self = .signedOut
        case "unavailable": self = .unavailable
        case "ready":
            let wallets = try values.decode([DeepSeekWallet].self, forKey: .wallets)
            let bonus = try values.decode([DeepSeekWallet].self, forKey: .bonusWallets)
            let url = try values.decode(String.self, forKey: .topUpURL)
            guard !wallets.isEmpty, Set(wallets.map(\.currency)).count == wallets.count,
                  Set(bonus.map(\.currency)).count == bonus.count,
                  isOfficialDeepSeekTopUpURL(url)
            else { throw DeepSeekBalanceValidation.invalidResponse }
            self = .ready(DeepSeekBalance(wallets: wallets, bonusWallets: bonus))
        default: throw DeepSeekBalanceValidation.invalidResponse
        }
    }
}

/// The actual production request seam. Every connection change and refresh invalidates
/// earlier work, including a reconnect to the same host and a late failed request.
@MainActor @Observable
public final class DeepSeekBalanceController {
    public enum State: Sendable, Equatable {
        case disconnected, idle, loading, unsupported, signedOut, unavailable, failed
        case ready(DeepSeekBalance)
    }

    public private(set) var state: State = .disconnected
    public private(set) var connectionTag: HostTag?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var readHost: (@MainActor () async throws -> HostInfo)?
    @ObservationIgnored private var readBalance: (@MainActor () async throws -> DeepSeekBalanceResponse)?

    public init() {}

    public func configure(
        tag: HostTag?,
        readHost: (@MainActor () async throws -> HostInfo)? = nil,
        readBalance: (@MainActor () async throws -> DeepSeekBalanceResponse)? = nil
    ) {
        generation += 1
        connectionTag = tag
        self.readHost = readHost
        self.readBalance = readBalance
        state = tag == nil ? .disconnected : .idle
    }

    public func refresh() async {
        guard connectionTag != nil, let readHost, let readBalance else {
            state = .disconnected
            return
        }
        generation += 1
        let request = generation
        state = .loading // Never display a previous amount during a new query.
        do {
            let host = try await readHost()
            guard request == generation, !Task.isCancelled else { return }
            guard host.hostId == connectionTag?.hostId else {
                state = .unsupported
                return
            }
            // The capability is a hint, not a second authorization gate. A host
            // that predates the plugin identity, or an app that decoded an older
            // `host.info`, can omit `plugin` while `account.balance` still works;
            // gating on the hint made the page say "unsupported" forever without
            // ever asking the account endpoint. Only an explicitly different
            // plugin is a definitive no; everything else asks, and the endpoint's
            // own `unsupported` status remains authoritative.
            if let plugin = host.plugin, plugin.id != "dsh-mizar" {
                state = .unsupported
                return
            }
            let response = try await readBalance()
            guard request == generation, !Task.isCancelled else { return }
            switch response {
            case .unsupported: state = .unsupported
            case .signedOut: state = .signedOut
            case .unavailable: state = .unavailable
            case .ready(let balance): state = .ready(balance)
            }
        } catch {
            guard request == generation, !Task.isCancelled else { return }
            state = .failed
        }
    }
}
