import Foundation
import Testing
@testable import MizarKit

@Suite("Official DeepSeek balance")
struct DeepSeekBalanceTests {
    private func decode(_ text: String) throws -> DeepSeekBalanceResponse {
        try JSONDecoder().decode(DeepSeekBalanceResponse.self, from: Data(text.utf8))
    }

    @Test func losslessWalletsAndRealZero() throws {
        let response = try decode(#"{"status":"ready","wallets":[{"currency":"CNY","balance":"12345678901234567890.00000000001"},{"currency":"USD","balance":"0"}],"bonusWallets":[{"currency":"CNY","balance":"1e-10"}],"topUpURL":"https://platform.deepseek.com/top_up"}"#)
        guard case .ready(let balance) = response else { Issue.record("expected ready"); return }
        #expect(balance.wallets[0].balance == "12345678901234567890.00000000001")
        #expect(balance.wallets[1].balance == "0")
        #expect(balance.bonusWallets[0].balance == "1e-10")
    }

    @Test(arguments: ["NaN", "Infinity", "", "one", "1.2.3", " 0", "0\n", "1e999x"])
    func invalidMoneyNeverBecomesZero(_ amount: String) {
        #expect(throws: (any Error).self) { try DeepSeekWallet(currency: "CNY", balance: amount) }
    }

    @Test func unsupportedCurrencyAndEmptyWalletsFail() {
        #expect(throws: (any Error).self) { try DeepSeekWallet(currency: "EUR", balance: "1") }
        #expect(throws: (any Error).self) {
            try decode(#"{"status":"ready","wallets":[],"bonusWallets":[],"topUpURL":"https://platform.deepseek.com/top_up"}"#)
        }
    }

    @Test(arguments: ["http://platform.deepseek.com/top_up", "https://platform.deepseek.com:443/top_up", "https://platform.deepseek.com:444/top_up", "https://evil.example/top_up", "https://u@platform.deepseek.com/top_up", "https://platform.deepseek.com/top_up?next=evil", "https://platform.deepseek.com/top_up#x"])
    func refusesNonOfficialLinks(_ link: String) {
        #expect(!isOfficialDeepSeekTopUpURL(link))
    }

    @MainActor @Test(arguments: [HostPlugin(id: "other", capabilities: ["deepseek.balance.v1"])])
    func explicitlyOtherPluginsNeverQueryBalance(_ plugin: HostPlugin?) async {
        let controller = DeepSeekBalanceController()
        var calls = 0
        controller.configure(tag: HostTag(hostId: "a", epoch: 1), readHost: { host("a", plugin) }, readBalance: {
            calls += 1
            return .unavailable
        })
        await controller.refresh()
        #expect(controller.state == .unsupported)
        #expect(calls == 0)
    }

    @MainActor @Test(arguments: [nil, HostPlugin(id: "dsh-mizar", capabilities: [])])
    func aMissingOrIncompleteHintStillAsksTheEndpoint(_ plugin: HostPlugin?) async {
        let controller = DeepSeekBalanceController()
        var calls = 0
        controller.configure(tag: HostTag(hostId: "a", epoch: 1), readHost: { host("a", plugin) }, readBalance: {
            calls += 1
            return .unavailable
        })
        await controller.refresh()
        #expect(controller.state == .unavailable)
        #expect(calls == 1)
    }

    @MainActor @Test func lateConnectionAndRefreshResultsAreRejected() async throws {
        let controller = DeepSeekBalanceController()
        let tag = HostTag(hostId: "a", epoch: 1)
        let gate = BalanceGate()
        controller.configure(tag: tag, readHost: { host("a") }, readBalance: { await gate.read() })
        let old = Task { await controller.refresh() }
        await gate.waitUntilStarted()
        // The same host over a replacement socket must be treated as a new subject.
        controller.configure(tag: HostTag(hostId: "a", epoch: 2), readHost: { host("a") }, readBalance: { .signedOut })
        await controller.refresh()
        gate.finish(.unavailable)
        await old.value
        #expect(controller.state == .signedOut)

        let second = BalanceGate()
        controller.configure(tag: tag, readHost: { host("a") }, readBalance: { await second.read() })
        let firstRefresh = Task { await controller.refresh() }
        await second.waitUntilStarted()
        // Refresh B finishes before refresh A on the *same* connection.
        let newer = Task { await controller.refresh() }
        await second.waitForReads(2)
        second.finish(.signedOut, index: 1)
        await newer.value
        second.finish(.unavailable, index: 0)
        await firstRefresh.value
        #expect(controller.state == .signedOut)

        controller.configure(tag: nil)
        #expect(controller.state == .disconnected)
    }

    @MainActor @Test func failureClearsPreviouslyReadyAmount() async throws {
        let ready = try decode(#"{"status":"ready","wallets":[{"currency":"CNY","balance":"0"}],"bonusWallets":[],"topUpURL":"https://platform.deepseek.com/top_up"}"#)
        let controller = DeepSeekBalanceController()
        var fail = false
        controller.configure(tag: HostTag(hostId: "a", epoch: 1), readHost: { host("a") }, readBalance: {
            if fail { throw DeepSeekBalanceValidation.invalidResponse }
            return ready
        })
        await controller.refresh()
        guard case .ready = controller.state else { Issue.record("expected a real ready amount"); return }
        fail = true
        await controller.refresh()
        #expect(controller.state == .failed)
    }
}

private func host(_ id: String, _ plugin: HostPlugin? = HostPlugin(id: "dsh-mizar", capabilities: ["deepseek.balance.v1"])) -> HostInfo {
    HostInfo(hostId: id, hostName: "Fixture", home: "/fixture", protocolVersion: 1, plugin: plugin)
}

@MainActor private final class BalanceGate {
    private var reads: [CheckedContinuation<DeepSeekBalanceResponse, Never>?] = []
    private var waiting: [(Int, CheckedContinuation<Void, Never>)] = []

    func read() async -> DeepSeekBalanceResponse {
        await withCheckedContinuation { continuation in
            reads.append(continuation)
            let ready = waiting.filter { reads.count >= $0.0 }
            waiting.removeAll { reads.count >= $0.0 }
            for (_, waiter) in ready { waiter.resume() }
        }
    }

    func waitUntilStarted() async { await waitForReads(1) }
    func waitForReads(_ count: Int) async {
        if reads.count >= count { return }
        await withCheckedContinuation { waiting.append((count, $0)) }
    }
    func finish(_ response: DeepSeekBalanceResponse, index: Int = 0) {
        let continuation = reads[index]
        reads[index] = nil
        continuation?.resume(returning: response)
    }
}
