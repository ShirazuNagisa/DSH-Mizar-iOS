//
//  SessionGoalPlanTests.swift
//  DSH-MizarTests
//
//  The pure decisions the session's goal and plan surfaces are built on. This
//  batch only has the model drawer's choice rule; the goal and plan types come
//  with their own surface.
//

import Foundation
import MizarKit
import Testing
@testable import DSH_Mizar

@MainActor
struct SessionGoalPlanTests {
    /// One catalogue row, decoded: `ModelOption` is the wire's own Decodable and
    /// has no public initialiser.
    ///
    /// - Parameters:
    ///   - efforts: the level ids the model accepts, in the host's order.
    ///   - defaultEffort: the level the provider applies when none is chosen.
    private static func option(efforts: [String], defaultEffort: String?) throws -> ModelOption {
        let levels = efforts
            .map { #"{ "id": "\#($0)", "name": "\#($0.capitalized)" }"# }
            .joined(separator: ", ")
        let fallback = defaultEffort.map { #""\#($0)""# } ?? "null"
        let json = """
        {
          "id": "pro",
          "name": "Pro",
          "description": null,
          "efforts": [\(levels)],
          "defaultEffort": \(fallback)
        }
        """
        return try JSONDecoder().decode(ModelOption.self, from: Data(json.utf8))
    }

    @Test func theNewModelKeepsALevelItAccepts() throws {
        let option = try Self.option(efforts: ["off", "low", "high"], defaultEffort: "low")

        // The level in force wins over the new model's default: switching model
        // is not a reason to also change how hard it thinks.
        #expect(ModelDrawerChoice.effort(for: option, keeping: "high") == "high")
    }

    @Test func aModelThatDoesNotTakeTheLevelFallsBackToItsDefault() throws {
        let option = try Self.option(efforts: ["off", "low"], defaultEffort: "low")

        #expect(ModelDrawerChoice.effort(for: option, keeping: "max") == "low")
    }

    @Test func aModelWithNoLevelsTakesNone() throws {
        let option = try Self.option(efforts: [], defaultEffort: nil)

        // Sending an effort to a model that accepts none is a hard error
        // upstream, not something that gets clamped.
        #expect(ModelDrawerChoice.effort(for: option, keeping: "high") == nil)
    }

    // MARK: - The top row's availability

    @Test func theTopRowNeedsARemoteDSHHost() {
        func available(
            sessionId: String = "dsh:session-1",
            isLocalAgent: Bool = false,
            hasDesktop: Bool = true,
            engineScope: AgentEngine? = .dsh,
        ) -> Bool {
            SessionGoalPlanAvailability.isDesktopDSH(
                sessionId: sessionId,
                isLocalAgent: isLocalAgent,
                hasDesktop: hasDesktop,
                engineScope: engineScope,
            )
        }

        // The on-device agent has no desktop behind it.
        #expect(available(isLocalAgent: true) == false)
        // A paired computer that does not report a desktop product.
        #expect(available(hasDesktop: false) == false)
        // A DSH-prefixed session from a desktop host.
        #expect(available(sessionId: "dsh:session-1", engineScope: nil) == true)
        // Another engine's prefixed session is not DSH, whatever the scope says.
        #expect(available(sessionId: "codex:session-1", engineScope: .dsh) == false)
        // No prefix: the scope decides, and no scope means DSH.
        #expect(available(sessionId: "session-1", engineScope: nil) == true)
        #expect(available(sessionId: "session-1", engineScope: .claude) == false)
    }

    // MARK: - Plan counts

    @Test func aPlanCountsItsCompletedStepsAndFindsARunningOne() {
        let plan = SessionPlan(steps: [
            SessionPlanStep(id: 0, content: "A", status: .completed),
            SessionPlanStep(id: 1, content: "B", status: .completed),
            SessionPlanStep(id: 2, content: "C", status: .inProgress),
            SessionPlanStep(id: 3, content: "D", status: .pending),
        ])

        #expect(plan.completedCount == 2)
        #expect(plan.hasStepInProgress == true)

        let finished = SessionPlan(steps: [
            SessionPlanStep(id: 0, content: "A", status: .completed),
            SessionPlanStep(id: 1, content: "B", status: .pending),
        ])
        #expect(finished.completedCount == 1)
        #expect(finished.hasStepInProgress == false)
    }

    // MARK: - Duration formatting

    @Test func theDurationSpellsMinutesAndSecondsAndDropsTheSecondsOnAWholeHour() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let end = start.addingTimeInterval(2200)

        // Pinned to English: the format follows the machine's locale, and an
        // assertion that names words is only true in the locale it names.
        let english = Locale(identifier: "en_US")
        #expect(SessionGoalDuration.text(from: start, to: end, locale: english) == "36 min, 40 sec")
        #expect(
            SessionGoalDuration.text(from: start, to: start.addingTimeInterval(7200), locale: english)
                == "2 hr",
        )
    }
}
