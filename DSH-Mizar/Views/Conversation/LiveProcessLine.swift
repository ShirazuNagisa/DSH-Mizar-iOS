//
//  LiveProcessLine.swift
//  DSH-Mizar
//
//  The one line a running turn shows, and the sentence it settles into.
//
//  DSH draws the same thing in its own conversation: while the agent works, a
//  single line says what it has done so far ("已完成分析并执行了命令"), with a
//  highlight sweeping across the text; when the answer starts arriving, that
//  line stops moving and becomes the heading for the answer. The wording here is
//  DSH's, copied rather than invented, because a phone and a desktop describing
//  the same turn differently is worse than either describing it alone.
//

import MizarKit
import SwiftUI

/// One kind of work a turn can have done, as DSH names it.
///
/// Ordered: two categories join with "并" in this order, so "已完成分析并执行了命令"
/// reads the way an operator narrates it.
enum ProcessCategory: Int, CaseIterable, Sendable {
    case thinking
    case read
    case edit
    case commands
    case search
    case subagents
    case plan
    case questions
    case tools
    case background
    case compacting

    /// DSH's completed-tense label.
    var label: String {
        switch self {
        case .thinking: return "已完成分析"
        case .read: return "已读取文件"
        case .edit: return "修改了文件"
        case .commands: return "执行了命令"
        case .search: return "已搜索代码"
        case .subagents: return "已协调子智能体"
        case .plan: return "更新了计划"
        case .questions: return "向用户提出了问题"
        case .tools: return "已调用工具"
        case .background: return "交给了后台任务"
        case .compacting: return "压缩了上下文"
        }
    }

    /// What the line says *while* the work is happening.
    ///
    /// Present tense, because it is true right now: the turn has not finished a
    /// step, it is in the middle of one. The past-tense label is drawn only
    /// after the fact, which is the moment the answer starts arriving.
    var runningLabel: String {
        switch self {
        case .thinking: return "正在分析"
        case .read: return "正在读取文件"
        case .edit: return "正在修改文件"
        case .commands: return "正在执行命令"
        case .search: return "正在搜索代码"
        case .subagents: return "正在协调子智能体"
        case .plan: return "正在更新计划"
        case .questions: return "正在向你提问"
        case .tools: return "正在调用工具"
        case .background: return "等待后台任务"
        case .compacting: return "正在压缩上下文"
        }
    }

    /// The category a state code implies, when it implies one.
    static func from(state: SessionState) -> ProcessCategory? {
        switch state {
        case .thinking: return .thinking
        case .tool: return .tools
        case .editing: return .edit
        case .subagent: return .subagents
        case .background: return .background
        case .compacting: return .compacting
        default: return nil
        }
    }
}

/// Compose the line DSH shows, from the categories a segment touched.
///
/// Same rules as `processTitle`: two join with "并", three or more with "，",
/// and anything past three is elided with "等". The shared "已" prefix is
/// dropped from the second label so "已…并…" does not repeat itself.
enum ProcessWording {
    static func compose(_ categories: Set<ProcessCategory>) -> String {
        let ordered = categories.sorted { $0.rawValue < $1.rawValue }
        guard let first = ordered.first else { return "已完成分析" }
        let labels = ordered.map(\.label)
        if labels.count == 1 { return first.label }
        if labels.count == 2 {
            return "\(labels[0])并\(continuation(labels[1], after: labels[0]))"
        }
        let rest = labels.dropFirst().map { continuation($0, after: labels[0]) }
        let title = ([labels[0]] + rest).joined(separator: "，")
        return labels.count > 3 ? "\(title)等" : title
    }

    /// "已读取文件" after "已完成分析" becomes "读取文件": one "已" is enough.
    private static func continuation(_ label: String, after first: String) -> String {
        guard first.hasPrefix("已"), label.hasPrefix("已") else { return label }
        return String(label.dropFirst())
    }
}

/// The live block a running turn draws in the conversation.
///
/// Two shapes, one component:
///
/// - before any body text: the action in progress, present tense, shimmering,
///   replaced in place whenever the state changes;
/// - once body text arrives: the tally of what the segment did, past tense and
///   still, with the text underneath it.
///
/// It sits in the conversation, after the last turn, because that is where the
/// answer is going to land -- a strip above the composer would be a second
/// place to look during the one moment the operator is watching.
struct LiveTurnBlock: View {
    /// The action happening right now, while the turn is still working.
    let running: ProcessCategory?
    /// Everything this segment did, for the frozen heading.
    let done: Set<ProcessCategory>
    /// The body text streamed so far, if any.
    let text: String

    private var headline: String {
        if text.isEmpty {
            return running?.runningLabel ?? "正在分析"
        }
        return ProcessWording.compose(done)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Group {
                if text.isEmpty {
                    Text(headline)
                        .font(.subheadline.weight(.medium))
                        // The accent, not the success green: this line is the
                        // app's own voice while it works, and DSH draws its
                        // running text in the accent too. Green is reserved for
                        // a turn that finished well.
                        .foregroundStyle(Color.accentColor)
                        .shimmering()
                } else {
                    Text(headline)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            // Swapped in place, not animated as layout: the line is the same
            // line with a new sentence, and a cross-fade is what "it changed its
            // mind about what it is doing" should look like.
            .contentTransition(.opacity)
            .animation(.snappy(duration: 0.18), value: headline)
            .frame(maxWidth: .infinity, alignment: .leading)

            if !text.isEmpty {
                Text(text)
                    .font(.callout)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
    }
}
