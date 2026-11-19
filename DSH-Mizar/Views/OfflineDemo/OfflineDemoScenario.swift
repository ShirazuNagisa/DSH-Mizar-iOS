import Foundation
import MizarKit

/// Bundled examples with in-memory turns. No host or account is needed to run them.
enum OfflineDemoScenario: String, CaseIterable, Identifiable {
    case workshop
    case research

    var id: Self { self }

    var symbol: String {
        switch self {
        case .workshop: "calendar"
        case .research: "book.closed"
        }
    }

    var title: String {
        switch self {
        case .workshop: String(localized: "demo.workshop.title")
        case .research: String(localized: "demo.research.title")
        }
    }

    var opening: String {
        switch self {
        case .workshop: String(localized: "demo.workshop.opening")
        case .research: String(localized: "demo.research.opening")
        }
    }

    var samplePrompt: String {
        switch self {
        case .workshop: String(localized: "demo.workshop.prompt")
        case .research: String(localized: "demo.research.prompt")
        }
    }

    var question: String {
        switch self {
        case .workshop: String(localized: "demo.workshop.question")
        case .research: String(localized: "demo.research.question")
        }
    }

    var options: [OfflineDemoOption] {
        switch self {
        case .workshop: [.indoor, .outdoor]
        case .research: [.fastCapture, .traceableEvidence]
        }
    }

    var fileName: String {
        switch self {
        case .workshop: "workshop-plan.md"
        case .research: "research-brief.md"
        }
    }

    var fileURL: URL? {
        Bundle.main.url(forResource: fileName, withExtension: nil)
    }

}

enum OfflineDemoOption: Equatable {
    case indoor
    case outdoor
    case fastCapture
    case traceableEvidence

    var title: String {
        switch self {
        case .indoor: String(localized: "demo.workshop.option.indoor")
        case .outdoor: String(localized: "demo.workshop.option.outdoor")
        case .fastCapture: String(localized: "demo.research.option.time")
        case .traceableEvidence: String(localized: "demo.research.option.evidence")
        }
    }

    private var guidance: String {
        switch self {
        case .indoor: String(localized: "demo.workshop.reply.indoor")
        case .outdoor: String(localized: "demo.workshop.reply.outdoor")
        case .fastCapture: String(localized: "demo.research.reply.time")
        case .traceableEvidence: String(localized: "demo.research.reply.evidence")
        }
    }

    func reply(outcome: ApprovalOutcome) -> String {
        let attachment = switch outcome {
        case .allowedOnce: String(localized: "demo.approval.allowed")
        case .rejected: String(localized: "demo.approval.rejected")
        }
        return guidance + "\n\n" + attachment
    }
}

struct OfflineDemoTurn: Identifiable, Equatable {
    enum Stage: Equatable {
        case question
        case approval(answer: OfflineDemoOption)
        case finished(answer: OfflineDemoOption, outcome: ApprovalOutcome)
    }

    let id = UUID()
    let prompt: String
    var stage: Stage = .question
}
