//
//  ModelSelectionResolutionTests.swift
//  DSH-MizarTests
//
//  Which model the composer bar names, and which one the picker says is in
//  force.
//
//  The bug these pin: after a switch, the button in the composer (not the sheet
//  it opens) kept naming the model the session had been on before the switch.
//  The bar read only the host's stats frame, and nothing refreshes that frame
//  on an idle session, while the picker read the switch this phone had had
//  accepted -- so the two named different models, and the button was the wrong
//  one. `agreedModelSelection` is now the single precedence both read; the
//  source contract keeps a future edit from splitting them again.
//

import MizarKit
import Testing
@testable import DSH_Mizar

struct ModelSelectionResolutionTests {
    /// A route with the provider every fixture agrees on.
    private func route(_ model: String, effort: String? = nil) -> ModelSelection {
        ModelSelection(provider: "deepseek-official", model: model, reasoningEffort: effort)
    }

    @Test func aSwitchThisPhoneMadeWinsOverTheHostsOlderFrame() {
        let chosen = route("deepseek-flash", effort: "high")
        let reported = ModelSelectionPair(
            lastUsed: route("deepseek-v4-pro", effort: "off"),
            next: route("deepseek-v4-pro", effort: "off"),
        )
        #expect(agreedModelSelection(chosen: chosen, reported: reported) == chosen)
    }

    @Test func theHostsPendingChangeWinsOverItsLastUsedRoute() {
        let pending = route("deepseek-flash", effort: "off")
        let reported = ModelSelectionPair(
            lastUsed: route("deepseek-v4-pro"),
            next: pending,
        )
        #expect(agreedModelSelection(chosen: nil, reported: reported) == pending)
    }

    @Test func theLastUsedRouteIsNamedWhenNothingIsPending() {
        let used = route("deepseek-v4-pro", effort: "high")
        let reported = ModelSelectionPair(lastUsed: used)
        #expect(agreedModelSelection(chosen: nil, reported: reported) == used)
    }

    @Test func theCatalogueDefaultNamesASessionThatHasNeverRun() {
        let fallback = route("deepseek-v4-pro")
        #expect(agreedModelSelection(chosen: nil, reported: nil, fallback: fallback) == fallback)
    }

    @Test func nothingIsNamedWhenNothingKnowsTheRoute() {
        #expect(agreedModelSelection(chosen: nil, reported: nil) == nil)
    }

    @Test func theBarAndThePickerResolveThroughTheSameFunction() throws {
        try AppSourceContract.expectFragments(
            ["agreedModelSelection("],
            in: "DSH-Mizar/Views/ComposerBar.swift",
            describing: "model resolution",
        )
        // The picker that used to read this from `Pickers.swift` is the model
        // drawer now; the contract moved with it rather than being dropped.
        try AppSourceContract.expectFragments(
            ["agreedModelSelection("],
            in: "DSH-Mizar/Views/Composer/ModelDrawer.swift",
            describing: "model resolution",
        )
    }
}
