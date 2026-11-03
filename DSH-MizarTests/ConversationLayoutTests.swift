import Testing
@testable import DSH_Mizar

@Suite("Conversation layout")
struct ConversationLayoutTests {
    @Test("a long conversation is lazy even with only a few turns")
    func longConversationIsLazy() {
        #expect(!ConversationView.canUseEagerStack(turnCount: 4, rowCount: 123))
    }

    @Test("a genuinely short page may be eager")
    func shortPageIsEager() {
        #expect(ConversationView.canUseEagerStack(turnCount: 4, rowCount: 40))
        #expect(ConversationView.canUseEagerStack(turnCount: 6, rowCount: 40))
        #expect(ConversationView.canUseEagerStack(turnCount: 0, rowCount: 40))
    }

    @Test("the thresholds do not let a flat long page through")
    func flatLongPageIsLazy() {
        #expect(!ConversationView.canUseEagerStack(turnCount: 0, rowCount: 41))
        #expect(!ConversationView.canUseEagerStack(turnCount: 7, rowCount: 1))
    }
}
