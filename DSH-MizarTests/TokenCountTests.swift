import Testing
@testable import DSH_Mizar

@MainActor
@Suite("Token count reading")
struct TokenCountTests {
    @Test("millions keep one decimal")
    func millions() {
        #expect(TurnResponseToolbar.compactTokens(26_600_000) == "26.6M")
    }

    @Test("a round unit drops the zero")
    func roundUnit() {
        #expect(TurnResponseToolbar.compactTokens(1_000_000) == "1M")
        #expect(TurnResponseToolbar.compactTokens(26_000_000) == "26M")
    }

    @Test("small counts stay exact")
    func small() {
        #expect(TurnResponseToolbar.compactTokens(999) == "999")
    }

    @Test("larger units use the same one-decimal rule")
    func largerUnits() {
        #expect(TurnResponseToolbar.compactTokens(26_600) == "26.6K")
        #expect(TurnResponseToolbar.compactTokens(26_600_000_000) == "26.6B")
        #expect(TurnResponseToolbar.compactTokens(9_000_000_000_000_000_000) == "9E")
    }
}
