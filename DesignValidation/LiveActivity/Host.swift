import UIKit

@main
struct ProductionValidationHost: App {
    var body: some Scene {
        WindowGroup {
            Text("Production Live Activity validation").task { await ProductionExporter.run() }
        }
    }
}

@MainActor
enum ProductionExporter {
    static var ran = false
    static func run() async {
        guard !ran else { return }; ran = true
        let output = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("ProductionExports")
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let now = Date()
        let sizes: [(String, DynamicTypeSize)] = [("large", .large), ("xl", .xLarge), ("xxxl", .xxxLarge), ("ax1", .accessibility1), ("ax3", .accessibility3), ("ax5", .accessibility5)]
        var records: [[String: Any]] = []
        for width in [371.0, 380.0, 408.0] {
            for (sizeName, size) in sizes {
                for scenario in ["running", "approval", "long", "long-action", "unknown"] {
                    let titles = ["修复登录验证", "运行项目测试", "更新接口文档", "整理发布说明"]
                    var rows: [LiveActivityRow] = []
                    for i in 0..<4 {
                        let title = scenario == "long" ? String(repeating: "修复跨设备审批与身份验证", count: 15) : titles[i]
                        let status: LiveActivitySessionStatus = scenario == "running" || i > 0 ? .running : .waitingApproval
                        let elapsed = Double(768 - i * 100)
                        let hostId = "host-\(i / 2)"
                        rows.append(.init(id: "same-\(i % 2)", prompt: "", title: title, elapsed: elapsed, countingSince: now.addingTimeInterval(-elapsed), hostId: hostId, hostName: i < 2 ? "MacBook" : "Mac mini", status: status))
                    }
                    let approvals = scenario == "running" ? [] : (0..<3).map { i in LiveActivityApproval(requestId: "request-\(i)", sessionId: rows[i].id, tool: "Edit", detail: scenario == "long-action" ? String(repeating: "修改项目认证文件的操作范围与目标路径", count: 20) : "修改认证文件", hostId: rows[i].hostId, hostName: rows[i].hostName, requestedAt: now.addingTimeInterval(Double(i))) }
                    var presentation = LiveActivityPresentation()
                    if scenario == "unknown", let first = approvals.first {
                        presentation.feedback[first.compositeId] = .init(phase: .unknown, message: "结果未确认，请进入详情核验")
                    }
                    LiveActivityPresentationStore.write(presentation)
                    let state = LiveActivityState(rows: rows, approvals: approvals)
                    let name = "\(Int(width))-\(sizeName)-\(scenario)"
                    let view = LiveActivityCard(state: state, appearance: .dark)
                        .environment(\.dynamicTypeSize, size)
                        .environment(\.locale, Locale(identifier: "zh-Hans"))
                        .frame(width: width)
                        .fixedSize(horizontal: false, vertical: true)
                    let controller = UIHostingController(rootView: view)
                    let fitting = controller.sizeThatFits(in: CGSize(width: width, height: 10000))
                    let renderer = ImageRenderer(content: view.background(Color(red: 0.04, green: 0.08, blue: 0.15), in: RoundedRectangle(cornerRadius: 24)))
                    renderer.scale = 2
                    if let data = renderer.uiImage?.pngData() { try? data.write(to: output.appendingPathComponent(name + ".png")) }
                    records.append(["name": name, "width": width, "height": fitting.height, "passed": fitting.height <= 160.5, "generatedAt": now.timeIntervalSince1970])
                }
            }
        }
        if let data = try? JSONSerialization.data(withJSONObject: records, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: output.appendingPathComponent("measurements.json"))
        }
    }
}
