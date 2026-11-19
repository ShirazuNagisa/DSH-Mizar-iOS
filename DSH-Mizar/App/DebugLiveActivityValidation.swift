#if DEBUG
import Foundation
import MizarKit
import ActivityKit

/// Opt-in device/simulator harness. Uses deliberately nonexistent requests, so
/// pressing a decision exercises the real route and must be refused without
/// side effects.
///
/// The original fixture (four sessions, three approvals) is still the default.
/// An optional `-mizarLiveActivityCase <name>` selects a smaller shape for
/// checking the compact clock without sending anything:
///
///     running   two running sessions, no approvals, 0:07 and 1:05
///     boundary  two running sessions, no approvals, one at 59:50
///     hour      two running sessions, no approvals, one just over an hour
///     long      two running sessions, no approvals, 62 and 66 minutes
///     approval  the original four sessions and three approvals
@MainActor
enum DebugLiveActivityValidation {
    static let enabled = ProcessInfo.processInfo.arguments.contains("-mizarLiveActivityValidation")
    static let start = Date()

    private static let caseName = argumentValue(for: "-mizarLiveActivityCase") ?? "approval"

    static func state(hosts: [PairedHost]) -> LiveActivityState {
        let validationHosts = validationHosts(hosts)
        switch caseName {
        case "running", "short":
            return running(hosts: validationHosts, elapsed: [7, 65])
        case "boundary":
            return running(hosts: validationHosts, elapsed: [3_590, 65])
        case "hour":
            return running(hosts: validationHosts, elapsed: [3_605, 65])
        case "long":
            return running(hosts: validationHosts, elapsed: [3_720, 3_960])
        default:
            return originalFixture(hosts: validationHosts)
        }
    }

    static func cleanup() async {
        for activity in Activity<DSHMizarActivityAttributes>.activities {
            let rows = activity.content.state.rows
            guard !rows.isEmpty, rows.allSatisfy({ $0.id.hasPrefix("live-validation-session-") }) else { continue }
            await activity.end(ActivityContent(state: .init(), staleDate: nil), dismissalPolicy: .immediate)
        }
    }

    // MARK: - Fixtures

    /// The original stub: four sessions waiting on the operator, three of them
    /// with pending approvals, and one running. Kept byte-for-byte in shape so
    /// the existing launch arguments still show the same card.
    private static func originalFixture(hosts: [(hostId: String, hostName: String)]) -> LiveActivityState {
        let titles = ["验证 · 登录流程", "验证 · 项目测试", "验证 · 接口文档", "验证 · 发布说明"]
        var rows: [LiveActivityRow] = []
        for i in 0..<4 {
            let elapsed = Double(768 - i * 100)
            let status: LiveActivitySessionStatus = i < 3 ? .waitingApproval : .running
            let host = hosts[i % hosts.count]
            rows.append(.init(id: "live-validation-session-\(i)", prompt: "", title: titles[i], elapsed: elapsed, countingSince: start.addingTimeInterval(-elapsed), hostId: host.hostId, hostName: host.hostName, status: status))
        }
        let approvals = (0..<3).map { i in
            let row = rows[i]
            return LiveActivityApproval(requestId: "live-validation-nonexistent-\(i)", sessionId: row.id, tool: "验证请求", detail: "核验连接，不会执行", hostId: row.hostId, hostName: row.hostName, requestedAt: start.addingTimeInterval(Double(i)))
        }
        return .init(rows: rows, approvals: approvals)
    }

    /// Two healthy running sessions and no approval: the compact island only has
    /// its brand mark and one clock, which is the state the phone failed.
    private static func running(
        hosts: [(hostId: String, hostName: String)],
        elapsed: [TimeInterval],
    ) -> LiveActivityState {
        let titles = ["验证 · 短计时", "验证 · 第二个会话"]
        let rows = elapsed.enumerated().map { index, seconds in
            let host = hosts[index % hosts.count]
            return LiveActivityRow(
                id: "live-validation-session-\(index)",
                prompt: "",
                title: titles[index % titles.count],
                elapsed: seconds,
                countingSince: start.addingTimeInterval(-seconds),
                hostId: host.hostId,
                hostName: host.hostName,
                status: .running,
            )
        }
        return .init(rows: rows, approvals: [])
    }

    private static func validationHosts(_ hosts: [PairedHost]) -> [(hostId: String, hostName: String)] {
        let pairedHosts = Array(hosts.prefix(2))
        return pairedHosts.isEmpty
            ? [
                ("validation-unpaired-a", "Validation Device A"),
                ("validation-unpaired-b", "Validation Device B"),
            ]
            : pairedHosts.enumerated().map { index, host in
                let fallbackName = "Validation Device \(index == 0 ? "A" : "B")"
                let name = host.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                return (host.hostId, name.isEmpty ? fallbackName : name)
            }
    }

    private static func argumentValue(for flag: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        for (index, argument) in arguments.enumerated() {
            if argument == flag, index + 1 < arguments.count { return arguments[index + 1] }
            if argument.hasPrefix(flag + "=") { return String(argument.dropFirst(flag.count + 1)) }
        }
        return nil
    }
}
#endif
