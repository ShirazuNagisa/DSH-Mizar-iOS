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
}
