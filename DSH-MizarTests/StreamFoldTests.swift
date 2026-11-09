//
//  StreamFoldTests.swift
//  DSH-MizarTests
//
//  How a settled turn is folded: the answer alone, the process behind the
//  header, and the way back to it.
//
//  The rule is pure on purpose. It is the part of the stream that decides
//  what a reader sees first and what they have to ask for, and it is the part
//  that is easiest to break by accident -- a body that arrives empty, a turn
//  that ends without an answer, a second final body. All of those are decided
//  here, so they are decided once.
//

import MizarKit
import Testing
@testable import DSH_Mizar

@Suite("Stream fold")
struct StreamFoldTests {
    private func status(_ id: Int) -> StreamBlock {
        StreamBlock(id: id, interval: UInt32(id), kind: .status, states: [.thinking])
    }

    private func body(_ id: Int, _ text: String, final: Bool = false) -> StreamBlock {
        StreamBlock(id: id, interval: UInt32(id), kind: .body, text: text, isFinal: final)
    }

    @Test("a running turn shows everything it has produced")
    func runningShowsEverything() {
        let blocks = [status(1), body(2, "我先看一下现有的实现。"), body(3, "改完了。", final: true)]
        let plan = StreamFold.plan(blocks: blocks, live: true, expanded: false)
        #expect(plan.showsProcess)
        #expect(plan.summary == nil)
        #expect(!plan.canExpand)
        #expect(plan.process.map(\.id) == [1, 2, 3])
    }

    @Test("a settled turn keeps only the answer")
    func settledFoldsTheProcess() {
        let blocks = [status(1), body(2, "我先看一下现有的实现。"), body(3, "改完了。", final: true)]
        let plan = StreamFold.plan(blocks: blocks, live: false, expanded: false)
        #expect(!plan.showsProcess)
        #expect(plan.canExpand)
        #expect(plan.summary?.id == 3)
        #expect(plan.process.map(\.id) == [1, 2])
        #expect(plan.after.isEmpty)
    }

    @Test("the process comes back in the order it was produced")
    func expandedKeepsTheOrder() {
        let blocks = [status(1), body(2, "我先看一下现有的实现。"), body(3, "改完了。", final: true)]
        let plan = StreamFold.plan(blocks: blocks, live: false, expanded: true)
        #expect(plan.showsProcess)
        #expect(plan.canExpand)
        #expect(plan.process.map(\.id) == [1, 2])
        #expect(plan.summary?.id == 3)
    }

    @Test("a turn that ended without an answer keeps its process")
    func noSummaryKeepsEverything() {
        let blocks = [status(1), body(2, "我先看一下现有的实现。")]
        let plan = StreamFold.plan(blocks: blocks, live: false, expanded: false)
        #expect(plan.summary == nil)
        #expect(!plan.canExpand)
        #expect(plan.showsProcess)
        #expect(plan.process.map(\.id) == [1, 2])
    }

    @Test("a turn with only an answer has nothing to fold")
    func onlyAnAnswer() {
        let blocks = [body(1, "改完了。", final: true)]
        let plan = StreamFold.plan(blocks: blocks, live: false, expanded: false)
        #expect(plan.summary?.id == 1)
        #expect(!plan.canExpand)
        #expect(plan.process.isEmpty)
        // Nothing is folded, so the header is not a button: there is no
        // process to bring back.
        #expect(!plan.showsProcess)
    }

    @Test("the answer is the last final body, not the first")
    func theLastFinalBodyIsTheAnswer() {
        let blocks = [body(1, "第一个答案", final: true), status(2), body(3, "第二个答案", final: true)]
        let plan = StreamFold.plan(blocks: blocks, live: false, expanded: false)
        #expect(plan.summary?.id == 3)
        #expect(plan.process.map(\.id) == [1, 2])
    }

    @Test("an empty final body is not an answer")
    func anEmptyFinalBodyIsNotAnAnswer() {
        let blocks = [status(1), body(2, "我先看一下现有的实现。"), body(3, "", final: true)]
        let plan = StreamFold.plan(blocks: blocks, live: false, expanded: false)
        #expect(plan.summary == nil)
        #expect(!plan.canExpand)
        #expect(plan.showsProcess)
        #expect(plan.process.map(\.id) == [1, 2, 3])
    }

    @Test("blocks after the answer keep their place")
    func blocksAfterTheAnswer() {
        let blocks = [status(1), body(2, "改完了。", final: true), status(3)]
        let plan = StreamFold.plan(blocks: blocks, live: false, expanded: true)
        #expect(plan.summary?.id == 2)
        #expect(plan.process.map(\.id) == [1])
        #expect(plan.after.map(\.id) == [3])
    }
}
