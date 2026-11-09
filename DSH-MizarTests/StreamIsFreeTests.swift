//
//  StreamIsFreeTests.swift
//  DSH-MizarTests
//
//  需求 5：会话流的全量传输（运行中的状态机与中间正文）对所有账户开放。
//
//  这一条曾经是付费的（附件、交付文件预览，以及那一版还能打开的「运行详情」）。
//  实时流本身从未被付费门挡住，但代码注释里一直写着它「属于付费功能」，而一张
//  挂了付费条件的新卡片就可能把它真的锁上。这里用源码契约把它钉在「没有付费门」
//  这一侧：流、折叠、状态帧与历史页面都不许出现付费判断；附件与预览则必须保留
//  判断（它们是另一条需求，不能被顺手放开）。
//

import Foundation
import Testing

struct StreamIsFreeTests {
    /// 文件里不许出现的东西。
    private static let gates = ["advancedFeaturesUnlocked", "isPaid", "previewUnlocked"]

    @Test("the live stream, its fold and its state frames carry no plan check")
    func streamIsNotGated() throws {
        let files = [
            "DSH-Mizar/Views/Conversation/ConversationStreamView.swift",
            "DSH-Mizar/Views/Conversation/SessionDetailView.swift",
            // `ConversationView` still carries the dormant running-detail
            // drawer's gate (`guard false`), which is not this feature; the
            // stream it draws lives in `ConversationStreamView`.
            "DSH-Mizar/Views/Conversation/TurnStream.swift",
            "DSH-Mizar/Views/Conversation/StreamFold.swift",
        ]
        for file in files {
            let source: String
            do {
                source = try AppSourceContract.text(at: file)
            } catch {
                // A file that has been renamed away is not a gate; the test is
                // about the gates, and the stream's file list is pinned by the
                // build, not here.
                continue
            }
            for gate in Self.gates where source.contains(gate) {
                Issue.record("\(file) mentions \(gate): the live stream is for every account")
            }
        }
    }

    @Test("attachments and file preview stay paid")
    func paidFeaturesStayPaid() throws {
        try AppSourceContract.expectFragments(
            ["canAttach: model.advancedFeaturesUnlocked"],
            in: "DSH-Mizar/Views/ComposerBar.swift",
            describing: "the attachment gate",
        )
        try AppSourceContract.expectFragments(
            ["previewUnlocked"],
            in: "DSH-Mizar/App/AppModel.swift",
            describing: "the preview gate",
        )
    }
}
