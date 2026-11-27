import MizarKit
import Testing
@testable import DSH_Mizar

@Suite("Onboarding navigation")
struct OnboardingNavigationTests {
    @Test("debug step raw values stay stable")
    func debugStepRawValues() {
        #expect(OnboardingStep.allCases.map(\.rawValue) == Array(0...10))
        #expect(OnboardingStep(rawValue: 3) == .connect)
        #expect(OnboardingStep(rawValue: 4) == .account)
        #expect(OnboardingStep(rawValue: 8) == .plan)
    }

    @Test("the official guide keeps its visible order")
    func officialOrdering() {
        #expect(OnboardingNavigation.visibleSteps(mode: .official) == [
            .welcome,
            .server,
            .desktop,
            .account,
            .network,
            .agent,
            .alerts,
            .plan,
            .refresh,
            .summary,
        ])
    }

    @Test("the self-hosted guide keeps its visible order")
    func selfHostedOrdering() {
        #expect(OnboardingNavigation.visibleSteps(mode: .selfHosted) == [
            .welcome,
            .server,
            .desktop,
            .connect,
            .network,
            .agent,
            .alerts,
            .refresh,
            .summary,
        ])
    }

    @Test("progress and adjacent navigation stop at visible boundaries")
    func visibleBoundaries() {
        let steps = OnboardingNavigation.visibleSteps(mode: .official)

        #expect(OnboardingNavigation.progressIndex(for: .welcome, in: steps) == 0)
        #expect(OnboardingNavigation.previousStep(before: .welcome, in: steps) == nil)
        #expect(OnboardingNavigation.nextStep(after: .welcome, in: steps) == .server)

        #expect(OnboardingNavigation.progressIndex(for: .summary, in: steps) == 9)
        #expect(OnboardingNavigation.previousStep(before: .summary, in: steps) == .refresh)
        #expect(OnboardingNavigation.nextStep(after: .summary, in: steps) == nil)
    }

    @Test("a debug-only page stays renderable but maps to the zero fallback")
    func debugOnlyPageMapping() {
        let official = OnboardingNavigation.visibleSteps(mode: .official)
        let selfHosted = OnboardingNavigation.visibleSteps(mode: .selfHosted)

        #expect(!official.contains(.connect))
        #expect(OnboardingNavigation.progressIndex(for: .connect, in: official) == 0)
        #expect(OnboardingNavigation.previousStep(before: .connect, in: official) == nil)
        #expect(OnboardingNavigation.nextStep(after: .connect, in: official) == nil)

        #expect(!selfHosted.contains(.account))
        #expect(!selfHosted.contains(.plan))
        #expect(OnboardingNavigation.progressIndex(for: .account, in: selfHosted) == 0)
        #expect(OnboardingNavigation.progressIndex(for: .plan, in: selfHosted) == 0)
    }

    @Test("account Continue permits signed-in users and returning operators")
    func accountContinue() {
        #expect(OnboardingNavigation.accountContinue(isSignedIn: true, isUpdate: false))
        #expect(OnboardingNavigation.accountContinue(isSignedIn: false, isUpdate: true))
        #expect(OnboardingNavigation.accountContinue(isSignedIn: true, isUpdate: true))
        #expect(!OnboardingNavigation.accountContinue(isSignedIn: false, isUpdate: false))
    }

    @Test("the official server ignores verification state")
    func officialServerContinue() {
        #expect(OnboardingNavigation.serverContinue(
            choice: .official,
            check: .idle,
            verifiedOrigin: nil,
            draft: .official,
        ))
        #expect(OnboardingNavigation.serverContinue(
            choice: .official,
            check: .checking,
            verifiedOrigin: nil,
            draft: .official,
        ))
        #expect(OnboardingNavigation.serverContinue(
            choice: .official,
            check: .failure("unreachable"),
            verifiedOrigin: nil,
            draft: .official,
        ))
        #expect(OnboardingNavigation.serverContinue(
            choice: .official,
            check: .success,
            verifiedOrigin: "https://relay.example.com",
            draft: .official,
        ))
    }

    @Test("self-hosted Continue requires success and a normalized origin match")
    func selfHostedServerContinue() {
        let draft = ServerSelection(mode: .selfHosted, origin: " Relay.Example.com/ ")

        #expect(!OnboardingNavigation.serverContinue(
            choice: .selfHosted,
            check: .idle,
            verifiedOrigin: "https://relay.example.com",
            draft: draft,
        ))
        #expect(!OnboardingNavigation.serverContinue(
            choice: .selfHosted,
            check: .checking,
            verifiedOrigin: "https://relay.example.com",
            draft: draft,
        ))
        #expect(!OnboardingNavigation.serverContinue(
            choice: .selfHosted,
            check: .failure("unreachable"),
            verifiedOrigin: "https://relay.example.com",
            draft: draft,
        ))
        #expect(OnboardingNavigation.serverContinue(
            choice: .selfHosted,
            check: .success,
            verifiedOrigin: "https://relay.example.com",
            draft: draft,
        ))
        #expect(!OnboardingNavigation.serverContinue(
            choice: .selfHosted,
            check: .success,
            verifiedOrigin: "https://other.example.com",
            draft: draft,
        ))
    }

    @Test("server Continue reads verification state and draft only when needed")
    func serverContinueReadsLazily() {
        var checkReads = 0
        var verifiedOriginReads = 0
        var draftReads = 0

        func check() -> OnboardingServerCheck {
            checkReads += 1
            return .checking
        }

        func verifiedOrigin() -> String? {
            verifiedOriginReads += 1
            return "https://relay.example.com"
        }

        func draft() -> ServerSelection {
            draftReads += 1
            return ServerSelection(mode: .selfHosted, origin: "relay.example.com")
        }

        let officialContinues = OnboardingNavigation.serverContinue(
            choice: .official,
            check: check(),
            verifiedOrigin: verifiedOrigin(),
            draft: draft(),
        )
        #expect(officialContinues)
        #expect(checkReads == 0)
        #expect(verifiedOriginReads == 0)
        #expect(draftReads == 0)

        let selfHostedContinuesWithIdleCheck = OnboardingNavigation.serverContinue(
            choice: .selfHosted,
            check: check(),
            verifiedOrigin: verifiedOrigin(),
            draft: draft(),
        )
        #expect(!selfHostedContinuesWithIdleCheck)
        #expect(checkReads == 1)
        #expect(verifiedOriginReads == 0)
        #expect(draftReads == 0)

        func successfulCheck() -> OnboardingServerCheck {
            checkReads += 1
            return .success
        }

        let selfHostedContinues = OnboardingNavigation.serverContinue(
            choice: .selfHosted,
            check: successfulCheck(),
            verifiedOrigin: verifiedOrigin(),
            draft: draft(),
        )
        #expect(selfHostedContinues)
        #expect(checkReads == 2)
        #expect(verifiedOriginReads == 1)
        #expect(draftReads == 1)
    }
}
