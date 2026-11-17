#if DEBUG
import Foundation
import MizarKit
import ActivityKit

/// Opt-in device harness. Uses deliberately nonexistent requests, so pressing
/// a decision exercises the real route and must be refused without side effects.
@MainActor
enum DebugLiveActivityValidation {
    static let enabled = ProcessInfo.processInfo.arguments.contains("-mizarLiveActivityValidation")
    static let start = Date()
    static func state(hosts: [PairedHost]) -> LiveActivityState {
        let pairedHosts = Array(hosts.prefix(2))
        let validationHosts: [(hostId: String, hostName: String)] = pairedHosts.isEmpty
            ? [
                ("validation-unpaired-a", "Validation Device A"),
                ("validation-unpaired-b", "Validation Device B"),
            ]
            : pairedHosts.enumerated().map { index, host in
                let fallbackName = "Validation Device \(index == 0 ? "A" : "B")"
                let name = host.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
                return (host.hostId, name.isEmpty ? fallbackName : name)
            }
        let titles = ["验证 · 登录流程", "验证 · 项目测试", "验证 · 接口文档", "验证 · 发布说明"]
        var rows: [LiveActivityRow] = []
        for i in 0..<4 {
            let elapsed = Double(768 - i * 100)
            let status: LiveActivitySessionStatus = i < 3 ? .waitingApproval : .running
            let host = validationHosts[i % validationHosts.count]
            rows.append(.init(id: "live-validation-session-\(i)", prompt: "", title: titles[i], elapsed: elapsed, countingSince: start.addingTimeInterval(-elapsed), hostId: host.hostId, hostName: host.hostName, status: status))
        }
        let approvals = (0..<3).map { i in
            let row = rows[i]
            return LiveActivityApproval(requestId: "live-validation-nonexistent-\(i)", sessionId: row.id, tool: "验证请求", detail: "核验连接，不会执行", hostId: row.hostId, hostName: row.hostName, requestedAt: start.addingTimeInterval(Double(i)))
        }
        return .init(rows: rows, approvals: approvals)
    }
    static func cleanup() async {
        for activity in Activity<DSHMizarActivityAttributes>.activities {
            let rows = activity.content.state.rows
            guard !rows.isEmpty, rows.allSatisfy({ $0.id.hasPrefix("live-validation-session-") }) else { continue }
            await activity.end(ActivityContent(state: .init(), staleDate: nil), dismissalPolicy: .immediate)
        }
    }

}
#endif
