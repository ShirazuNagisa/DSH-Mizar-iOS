//
//  AgentEngine.swift
//  DSH-Mizar
//
//  Which agent on the computer this phone is talking to.
//
//  A computer runs three agents at once and they do not share sessions, working
//  directories or even tool surfaces. A phone that wants to drive Claude Code is
//  not "a phone connected to the Mac" in any useful sense -- it is a phone
//  connected to the Mac's Claude Code, and the other two lists would be noise
//  and, worse, a way to send a prompt to the wrong agent.
//
//  The choice is made once, when the computer is opened, and travels in the
//  token: the relay asks the computer to mint a token scoped to it, and the
//  computer refuses to list or answer anything else.
//

import Foundation
import MizarKit

/// The agents a computer can serve.
enum AgentEngine: String, CaseIterable, Sendable, Identifiable {
    case dsh
    case claude
    case codex

    var id: String { rawValue }

    /// The name the wire uses (`EngineId::as_str` on the desktop).
    var wireName: String { rawValue }

    /// The prefix a session id carries, e.g. `dsh:session-…`.
    var sessionPrefix: String { "\(rawValue):" }

    /// What the picker calls it.
    ///
    /// A product name, so it is not translated: DSH is DSH in every language.
    var title: String {
        switch self {
        case .dsh: return "DSH"
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        }
    }

    /// One line under the name.
    var detail: String {
        switch self {
        case .dsh:
            String(localized: "DeepSeek Harness workspaces and sessions")
        case .claude:
            String(localized: "Claude Code transcripts on this computer")
        case .codex:
            String(localized: "Codex threads on this computer")
        }
    }

    /// What a workspace heading calls it when the list names its agent.
    ///
    /// Shorter than ``title`` on purpose: this is a capsule beside a folder name
    /// in a drawer, not a row in a picker.
    var shortTitle: String {
        switch self {
        case .dsh: return "DSH"
        case .claude: return "Claude"
        case .codex: return "Codex"
        }
    }
}

/// The two surfaces a coding agent shows on a computer.
///
/// The host still speaks three engine scopes; the phone's picker presents five
/// destinations because a GUI transcript and a CLI conversation are different
/// things to open, even when the same binary writes both.
enum AgentSurface: String, CaseIterable, Sendable {
    case gui
    case cli
}

/// One row in the phone's Agent picker.
struct AgentTarget: Hashable, Identifiable, Sendable {
    let engine: AgentEngine
    let surface: AgentSurface?

    var id: String {
        surface.map { "\(engine.rawValue)-\($0.rawValue)" } ?? engine.rawValue
    }

    /// What the picker calls it.
    var title: String {
        switch (engine, surface) {
        case (.dsh, _): return "DSH"
        case (.claude, .gui): return "CC GUI"
        case (.claude, .cli): return "CC CLI"
        case (.codex, .gui): return "Codex GUI"
        case (.codex, .cli): return "Codex CLI"
        case (.claude, nil): return "Claude Code"
        case (.codex, nil): return "Codex"
        }
    }

    /// One line under the name.
    var detail: String {
        switch (engine, surface) {
        case (.dsh, _):
            return String(localized: "DeepSeek Harness workspaces and sessions")
        case (.claude, .gui):
            return String(localized: "Claude Desktop transcripts, read-only")
        case (.claude, .cli):
            return String(localized: "Claude Code conversations on this computer")
        case (.codex, .gui):
            return String(localized: "Codex Desktop threads")
        case (.codex, .cli):
            return String(localized: "Codex CLI threads on this computer")
        case (.claude, nil):
            return String(localized: "Claude Code transcripts on this computer")
        case (.codex, nil):
            return String(localized: "Codex threads on this computer")
        }
    }

    /// GUI/CLI split targets are still experimental.
    var isExperimental: Bool { engine != .dsh }

    /// The localized marker appended to every experimental target.
    var experimentalSuffix: String { String(localized: "(Experimental)") }

    /// The name the picker rows draw, with the marker to its right.
    var experimentalTitle: String {
        isExperimental ? "\(title) \(experimentalSuffix)" : title
    }

    /// The shorter label a workspace capsule can use.
    var shortTitle: String {
        switch (engine, surface) {
        case (.dsh, _): return "DSH"
        case (.claude, .gui): return "CC GUI"
        case (.claude, .cli): return "CC CLI"
        case (.codex, .gui): return "Codex GUI"
        case (.codex, .cli): return "Codex CLI"
        case (.claude, nil): return "Claude"
        case (.codex, nil): return "Codex"
        }
    }

    /// The capsule label, marked when this target is experimental.
    var capsuleTitle: String {
        isExperimental ? "\(shortTitle) \(experimentalSuffix)" : shortTitle
    }

    /// The five destinations, always in the same order.
    static let all: [AgentTarget] = [
        AgentTarget(engine: .dsh, surface: nil),
        AgentTarget(engine: .claude, surface: .gui),
        AgentTarget(engine: .claude, surface: .cli),
        AgentTarget(engine: .codex, surface: .gui),
        AgentTarget(engine: .codex, surface: .cli),
    ]
}
