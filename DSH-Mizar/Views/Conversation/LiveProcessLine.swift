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

    /// DSH's completed-tense label, in the app's language.
    var label: String {
        switch self {
        case .thinking: return String(localized: "Analysed")
        case .read: return String(localized: "Read files")
        case .edit: return String(localized: "Edited files")
        case .commands: return String(localized: "Ran commands")
        case .search: return String(localized: "Searched code")
        case .subagents: return String(localized: "Coordinated subagents")
        case .plan: return String(localized: "Updated the plan")
        case .questions: return String(localized: "Asked questions")
        case .tools: return String(localized: "Called tools")
        case .background: return String(localized: "Handed to the background")
        case .compacting: return String(localized: "Compacted the context")
        }
    }

    /// A small glyph that names the same state as the word.
    var symbol: String {
        switch self {
        case .thinking: return "brain"
        case .read: return "doc.text"
        case .edit: return "pencil"
        case .commands: return "terminal"
        case .search: return "magnifyingglass"
        case .subagents: return "person.2"
        case .plan: return "list.bullet"
        case .questions: return "questionmark.bubble"
        case .tools: return "wrench.and.screwdriver"
        case .background: return "clock.arrow.circlepath"
        case .compacting: return "arrow.down.right.and.arrow.up.left"
        }
    }

    /// What the line says *while* the work is happening.
    ///
    /// Present tense, because it is true right now: the turn has not finished a
    /// step, it is in the middle of one. The past-tense label is drawn only
    /// after the fact, which is the moment the answer starts arriving.
    var runningLabel: String {
        switch self {
        case .thinking: return String(localized: "Analysing")
        case .read: return String(localized: "Reading files")
        case .edit: return String(localized: "Editing files")
        case .commands: return String(localized: "Running commands")
        case .search: return String(localized: "Searching code")
        case .subagents: return String(localized: "Coordinating subagents")
        case .plan: return String(localized: "Updating the plan")
        case .questions: return String(localized: "Asking you questions")
        case .tools: return String(localized: "Calling tools")
        case .background: return String(localized: "Waiting for the background")
        case .compacting: return String(localized: "Compacting the context")
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
        guard let first = ordered.first else { return String(localized: "Analysed") }
        let labels = ordered.map(\.label)
        if labels.count == 1 { return first.label }
        if isChinese {
            if labels.count == 2 {
                return "\(labels[0])并\(continuation(labels[1], after: labels[0]))"
            }
            let rest = labels.dropFirst().map { continuation($0, after: labels[0]) }
            let title = ([labels[0]] + rest).joined(separator: "，")
            return labels.count > 3 ? "\(title)等" : title
        }
        if labels.count == 2 {
            return "\(labels[0]) and \(labels[1])"
        }
        let title = labels.dropLast().joined(separator: ", ") + " and " + labels[labels.count - 1]
        return labels.count > 3 ? title + " etc." : title
    }

    private static var isChinese: Bool {
        Locale.current.language.languageCode?.identifier == "zh"
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
            return running?.runningLabel ?? String(localized: "Analysing")
        }
        return ProcessWording.compose(done)
    }

    /// The category whose glyph and wording lead the line.
    private var headlineCategory: ProcessCategory {
        if text.isEmpty { return running ?? .thinking }
        return done.sorted { $0.rawValue < $1.rawValue }.first ?? .thinking
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: headlineCategory.symbol)
                    .font(.subheadline.weight(.medium))
                Text(headline)
                    .font(.subheadline)
            }
            // Done lines stay quiet; the running line is the one that moves
            // and takes the accent.
            .foregroundStyle(text.isEmpty ? Theme.accentText : Color.secondary)
            .modifier(LiveShimmer(active: text.isEmpty))
            // Swapped in place, not animated as layout: the line is the same
            // line with a new sentence, and a cross-fade is what "it changed its
            // mind about what it is doing" should look like.
            .contentTransition(.opacity)
            .animation(.snappy(duration: 0.18), value: headline)
            .frame(maxWidth: .infinity, alignment: .leading)

            if !text.isEmpty {
                Text(text)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
    }
}

/// The sweep on the running line, applied to the whole row so the glyph moves
/// with the words instead of staying still beside them.
private struct LiveShimmer: ViewModifier {
    let active: Bool
    @ViewBuilder
    func body(content: Content) -> some View {
        if active { content.shimmering() } else { content }
    }
}
