//
//  OnboardingNavigation.swift
//  DSH-Mizar
//
//  Pure navigation and Continue rules for the first-run guide.
//

import MizarKit

/// Every page the guide knows how to render.
///
/// The raw values are also the debug launch values, so their order and numbers
/// stay stable even when a particular server mode hides a page.
enum OnboardingStep: Int, CaseIterable, Identifiable {
    case welcome, server, desktop, connect, account, network, agent, alerts, plan, refresh, summary

    var id: Int { rawValue }
}

/// Everything the server page's verification can be doing.
enum OnboardingServerCheck: Equatable {
    case idle
    case checking
    case success
    case failure(String)
}

enum OnboardingNavigation {
    static func visibleSteps(mode: ServerMode) -> [OnboardingStep] {
        if mode == .selfHosted {
            return [.welcome, .server, .desktop, .connect, .network, .agent, .alerts, .refresh, .summary]
        }
        return [.welcome, .server, .desktop, .account, .network, .agent, .alerts, .plan, .refresh, .summary]
    }

    static func progressIndex(for step: OnboardingStep, in visibleSteps: [OnboardingStep]) -> Int {
        visibleSteps.firstIndex(of: step) ?? 0
    }

    static func previousStep(
        before step: OnboardingStep,
        in visibleSteps: [OnboardingStep],
    ) -> OnboardingStep? {
        guard let index = visibleSteps.firstIndex(of: step), index > 0 else { return nil }
        return visibleSteps[index - 1]
    }

    static func nextStep(
        after step: OnboardingStep,
        in visibleSteps: [OnboardingStep],
    ) -> OnboardingStep? {
        guard let index = visibleSteps.firstIndex(of: step), index + 1 < visibleSteps.count else {
            return nil
        }
        return visibleSteps[index + 1]
    }

    /// A signed-in account always continues. A returning operator may keep the
    /// account they have, including no account, while retaking the guide.
    static func accountContinue(isSignedIn: Bool, isUpdate: Bool) -> Bool {
        isSignedIn || isUpdate
    }

    /// The official server needs no verification. A self-hosted server has to
    /// answer at the normalized origin that is currently in the draft.
    static func serverContinue(
        choice: ServerMode,
        check: @autoclosure () -> OnboardingServerCheck,
        verifiedOrigin: @autoclosure () -> String?,
        draft: @autoclosure () -> ServerSelection,
    ) -> Bool {
        guard choice == .selfHosted else { return true }
        guard check() == .success else { return false }
        let origin = verifiedOrigin()
        return origin == draft().normalizedOrigin
    }
}
