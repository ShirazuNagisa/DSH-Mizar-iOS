//
//  ConversationTests.swift
//  MizarKitTests
//
//  The fixtures here are trimmed copies of records a live host actually returned,
//  including the failure that every turn on this machine ends with. Guessing at
//  the shapes would have produced a green suite that rendered nothing.
//

import Foundation
import Testing
@testable import MizarKit

/// Decode a page from JSON text.
private func page(_ json: String) throws -> SessionMessagesResult {
    try JSONDecoder().decode(SessionMessagesResult.self, from: Data(json.utf8))
}

@Suite("Conversation")
struct ConversationTests {
    @Test("a page carries the context figure, and a page without one is unknown")
    func pageContext() throws {
        // Every page carries it -- full refresh and data-saving incremental
        // refresh alike, from the same projection baseline that names the cut --
        // which is what keeps the composer's occupancy figure current while a
        // turn runs.
        let withContext = try page("""
        {"sessionId":"s1","asOfSeq":17,"hasMore":false,"context":{
          "window":128000,"pressureTokens":60000,"projectedTokens":64000,"percent":50,
          "breakdown":{"systemTokens":1000,"toolsTokens":2000,"messageTokens":3000}},
         "records":[]}
        """)
        #expect(withContext.context?.window == 128_000)
        #expect(withContext.context?.pressureTokens == 60_000)
        #expect(withContext.context?.projectedTokens == 64_000)
        #expect(withContext.context?.percent == 50)
        #expect(withContext.context?.breakdown?.messageTokens == 3_000)

        // An older plugin omits the key. That is unknown, not an empty window:
        // the app must keep whatever frame it already had.
        let withoutContext = try page("""
        {"sessionId":"s1","asOfSeq":17,"hasMore":false,"records":[]}
        """)
        #expect(withoutContext.context == nil)
    }

    @Test("a user message becomes a bubble")
    func userMessage() throws {
        let result = try page("""
        {"sessionId":"s1","asOfSeq":17,"hasMore":false,"records":[
          {"type":"event","event":{"type":"user/message","seq":8,"time":1791984791224,
            "data":{"content":[{"type":"text","text":"Reply with exactly: hello"}],
                      "source":{"kind":"user"},"role":"user","id":"abc"},"surfaceOp":"append"}}
        ]}
        """)

        let items = result.conversationItems()
        #expect(items.count == 1)
        guard case .message(_, let role, let text, _) = items[0] else {
            Issue.record("expected a message, got \(items[0])")
            return
        }
        #expect(role == .user)
        #expect(text == "Reply with exactly: hello")
    }

    @Test("several text parts are joined")
    func multipartMessage() throws {
        let result = try page("""
        {"sessionId":"s1","asOfSeq":1,"hasMore":false,"records":[
          {"type":"event","event":{"type":"user/message","seq":1,"time":1,
            "data":{"source":{"kind":"user"},"content":[{"type":"text","text":"one"},{"type":"image","url":"x"},
                               {"type":"text","text":"two"}]}}}
        ]}
        """)
        guard case .message(_, _, let text, _) = result.conversationItems()[0] else {
            Issue.record("expected a message")
            return
        }
        #expect(text == "one\ntwo")
    }

    @Test("a failed turn is shown as a failure, not as an empty answer")
    func failedTurn() throws {
        // This is the real shape: every turn on a host without a provider
        // credential ends here, and showing nothing would look like a hang. The
        // history is summary-only now, so the reason arrives on the turn's one
        // message rather than on a stream of chunks inside an attempt.
        let result = try page("""
        {"sessionId":"s1","asOfSeq":15,"hasMore":false,"records":[
          {"type":"event","event":{"type":"turn/start","seq":14,"time":1,"data":{"turn":1}}},
          {"type":"event","event":{"type":"assistant/message","seq":15,"time":2,
            "data":{"turn":1,"step":1,"message":{"role":"assistant","content":[]},
                     "stopReason":{"kind":"error",
                       "message":"llm-deepseek: no API key for provider route deepseek-official"}}}},
          {"type":"event","event":{"type":"turn/end","seq":16,"time":3,
            "data":{"turn":1,"reason":{"kind":"error"}}}}
        ]}
        """)
        guard case .failure(_, let message, _) = result.conversationItems().first else {
            Issue.record("expected a failure, got \(result.conversationItems())")
            return
        }
        #expect(message.contains("no API key"))
    }

    @Test("bookkeeping events are dropped rather than rendered")
    func bookkeepingIsDropped() throws {
        // One prompt emits roughly sixteen of these for every two messages --
        // measured on a live session, not estimated. A conversation view that
        // lists them is a list of bookkeeping rows with two lines of dialogue
        // somewhere inside it.
        let result = try page("""
        {"sessionId":"s1","asOfSeq":6,"hasMore":false,"records":[
          {"type":"event","event":{"type":"permission/preset","seq":0,"time":1,"data":{}}},
          {"type":"event","event":{"type":"sandbox/mode","seq":1,"time":1,"data":{}}},
          {"type":"event","event":{"type":"approval/policy","seq":2,"time":1,"data":{}}},
          {"type":"event","event":{"type":"agent/inbox/spliced","seq":3,"time":1,"data":{}}},
          {"type":"event","event":{"type":"turn/start","seq":4,"time":1,"data":{}}},
          {"type":"event","event":{"type":"step/start","seq":5,"time":1,"data":{}}},
          {"type":"event","event":{"type":"something/entirely-new","seq":6,"time":1,"data":{}}}
        ]}
        """)
        #expect(result.conversationItems().isEmpty)
    }

    @Test("a packed chunk run is not mistaken for a message")
    func chunkRun() throws {
        let result = try page("""
        {"sessionId":"s1","asOfSeq":1,"hasMore":false,"records":[
          {"type":"chunks","event":{"type":"assistant/delta","seq":1,"time":1,"data":{}}}
        ]}
        """)
        #expect(result.conversationItems().isEmpty)
    }

    @Test("injected context is not shown as something the operator said")
    func injectedContextIsHidden() throws {
        // The bug this pins, measured on a live session: an eleven-character
        // prompt arrived alongside 483 characters of runtime context and 5921
        // characters of skill catalogue, all as `user/message`. Rendered as
        // bubbles, they buried the conversation -- which read as the app having
        // lost its history, and it had.
        let result = try page("""
        {"sessionId":"s1","asOfSeq":10,"hasMore":false,"records":[
          {"type":"event","event":{"type":"user/message","seq":8,"time":1,
            "data":{"source":{"kind":"user"},"content":[{"type":"text","text":"hello world"}]}}},
          {"type":"event","event":{"type":"user/message","seq":9,"time":1,
            "data":{"source":{"kind":"runtime-context"},"content":[{"type":"text","text":"Current runtime context. This snapshot supersedes"}]}}},
          {"type":"event","event":{"type":"user/message","seq":10,"time":1,
            "data":{"source":{"kind":"skill-catalog"},"content":[{"type":"text","text":"<system-reminder>A skill is a reusable set"}]}}}
        ]}
        """)
        let items = result.conversationItems()
        #expect(items.count == 1)
        guard case .message(_, let role, let text, _) = items[0] else {
            Issue.record("expected one message, got \(items)")
            return
        }
        #expect(role == .user)
        #expect(text == "hello world")
    }

    @Test("the agent's own notices are not the operator speaking")
    func noticesAreNotPrompts() throws {
        // The census, from a real session log. Every `user/message` by
        // `source.kind`, and only the first is a person:
        //
        //     13  user                the operator, typing
        //      7  tool-jobs           a background job finished
        //      6  runtime-context     injected context
        //      4  subagent-settled    a subagent stopped
        //      3  skill-catalog       injected skill list
        //      3  goal                a goal round
        //      2  user-approval       a notice *about* a user action
        //      2  agent-message       another agent talking
        //      2  compact-checkpoint  the conversation was compacted
        //      1  model-selection     the model was changed
        //      1  plan-mode           the mode was changed
        //
        // Nine of those eleven arrived as ordinary user messages. A blocklist
        // naming two of them let the rest through, which is the pile of things
        // the operator never typed.
        let kinds = [
            "tool-jobs", "runtime-context", "subagent-settled", "skill-catalog",
            "goal", "user-approval", "agent-message", "compact-checkpoint",
            "model-selection", "plan-mode",
        ]
        let records = kinds.enumerated().map { index, kind in
            """
            {"type":"event","event":{"type":"user/message","seq":\(index + 1),"time":\(index + 1),
              "data":{"source":{"kind":"\(kind)"},"content":[{"type":"text","text":"not mine"}]}}}
            """
        }.joined(separator: ",")
        let result = try page("""
        {"sessionId":"s1","asOfSeq":20,"hasMore":false,"records":[\(records)]}
        """)
        #expect(result.conversationItems().isEmpty)
    }

    @Test("a message typed on the computer is shown, because it carries the same kind")
    func desktopMessageIsShown() throws {
        // There is no `desktop` kind in the log. A message typed in the computer's
        // own DSH window carries `user` like any other, which is why asking for
        // that kind by name loses nothing a person wrote -- the earlier change
        // to a blocklist was made to recover messages that were never being
        // hidden by the allowlist in the first place.
        let result = try page("""
        {"sessionId":"s1","asOfSeq":2,"hasMore":false,"records":[
          {"type":"event","event":{"type":"user/message","seq":1,"time":1,
            "data":{"source":{"kind":"user"},"content":[{"type":"text","text":"from the computer"}]}}}
        ]}
        """)
        #expect(result.conversationItems().count == 1)
    }

    @Test("a message with no source is not treated as the operator's")
    func missingSourceIsHidden() throws {
        // Every `user/message` in the census carries a kind, so an absent one is
        // an anomaly rather than a person. Guessing in that direction is how the
        // pile got here.
        let result = try page("""
        {"sessionId":"s1","asOfSeq":1,"hasMore":false,"records":[
          {"type":"event","event":{"type":"user/message","seq":1,"time":1,
            "data":{"content":[{"type":"text","text":"no source at all"}]}}}
        ]}
        """)
        #expect(result.conversationItems().isEmpty)
    }

    @Test("the model's reply is shown")
    func assistantMessageIsShown() throws {
        // `assistant/message` is the committed reply and was the one event type
        // the parser did not know. A model that answered perfectly produced
        // nothing on the phone while the computer showed the whole exchange.
        let result = try page("""
        {"sessionId":"s1","asOfSeq":3,"hasMore":false,"records":[
          {"type":"event","event":{"type":"user/message","seq":1,"time":1,
            "data":{"source":{"kind":"user"},"content":[{"type":"text","text":"what is 2+2"}]}}},
          {"type":"event","event":{"type":"assistant/message","seq":2,"time":2,
            "data":{"content":[{"type":"text","text":"4"}]}}}
        ]}
        """)
        let items = result.conversationItems()
        #expect(items.count == 2)
        guard case .message(_, let role, let text, _) = items[1] else {
            Issue.record("expected the reply, got \(items[1])")
            return
        }
        #expect(role == .assistant)
        #expect(text == "4")
    }

    @Test("a record the transport stopped sending renders nothing, not a crash")
    func retiredRecordTypesAreIgnored() throws {
        // `assistant/attempt` and `system/message` are no longer sent -- the
        // history is summary-only -- but a cache, or a host a version behind,
        // can still hold them, and a parser that cannot read what it is handed
        // is a screen that shows nothing at all. They contribute nothing, which
        // is the correct amount: the turn's own `assistant/message` is the
        // answer, and the attempt behind it is the narration that was dropped.
        let result = try page("""
        {"sessionId":"s1","asOfSeq":3,"hasMore":false,"records":[
          {"type":"event","event":{"type":"assistant/attempt","seq":2,"time":1,
            "data":{"turn":1,"step":1,"stream":[
              {"type":"chunk","chunk":{"type":"delta","text":"Hel"}},
              {"type":"chunk","chunk":{"type":"delta","text":"lo"}}]}}},
          {"type":"event","event":{"type":"system/message","seq":3,"time":2,
            "data":{"turn":1,"step":1,"message":{"role":"system","content":[
              {"type":"text","text":"You are an AI agent powered by DeepSeek Harness."}]}}}}
        ]}
        """)
        #expect(result.conversationItems().isEmpty)
    }

    @Test("the same prompt arriving twice is shown once")
    func duplicatePrompt() throws {
        // A prompt arrives as two user/message events with identical text -- one
        // carrying the RPC source, one from the inbox splice.
        let result = try page("""
        {"sessionId":"s1","asOfSeq":9,"hasMore":false,"records":[
          {"type":"event","event":{"type":"user/message","seq":8,"time":1,
            "data":{"source":{"kind":"user"},"content":[{"type":"text","text":"hello"}]}}},
          {"type":"event","event":{"type":"user/message","seq":9,"time":1,
            "data":{"source":{"kind":"user"},"content":[{"type":"text","text":"hello"}]}}}
        ]}
        """)
        #expect(result.conversationItems().count == 1)
    }

    @Test("an empty page produces nothing rather than a placeholder")
    func emptyPage() throws {
        let result = try page("""
        {"sessionId":"s1","asOfSeq":null,"hasMore":false,"records":[]}
        """)
        #expect(result.conversationItems().isEmpty)
    }

    // MARK: - Shapes taken from a real session log

    @Test("the model's reply is found where a real log puts it")
    func assistantMessageRealShape() throws {
        // Copied from a live session log, trimmed. The text is at
        // `data.message.content`, one key deeper than a user message's
        // `data.content` -- and reading only the latter is why every reply was
        // missing from the phone while the computer showed the whole exchange.
        let result = try page("""
        {"sessionId":"s1","asOfSeq":29,"hasMore":false,"records":[
          {"type":"event","event":{"type":"assistant/message","seq":29,"time":1791089307181,
            "data":{"turn":2,"step":1,"message":{"role":"assistant","content":[
              {"type":"reasoning","text":""},
              {"type":"text","text":"I will start by exploring the workspace."},
              {"type":"tool-call","id":"call_1","name":"bash","arguments":"{}"}
            ],"source":{"kind":"model","provider":"deepseek-account","model":"deepseek-flash"}},
            "surfaceOp":"append"}}}
        ]}
        """)
        let items = result.conversationItems()
        #expect(items.count == 1)
        guard case .message(_, let role, let text, _) = items[0] else {
            Issue.record("expected the reply, got \(items)")
            return
        }
        #expect(role == .assistant)
        #expect(text == "I will start by exploring the workspace.")
    }

    @Test("a tool-call-only reply produces no bubble")
    func assistantMessageWithoutText() throws {
        // A step that only calls tools has no text to show, and an empty bubble
        // per tool call would be worse than nothing.
        let result = try page("""
        {"sessionId":"s1","asOfSeq":30,"hasMore":false,"records":[
          {"type":"event","event":{"type":"assistant/message","seq":30,"time":1,
            "data":{"message":{"role":"assistant","content":[
              {"type":"tool-call","id":"c","name":"bash","arguments":"{}"}
            ]}}}}
        ]}
        """)
        #expect(result.conversationItems().isEmpty)
    }

    @Test("the system prompt is not shown as a message")
    func systemPromptIsHidden() throws {
        // Copied from a real session: `system/message` carries the whole prompt
        // DSH hands the model, several thousand characters of it, at the top of
        // every conversation. It is not something either party said.
        let result = try page("""
        {"sessionId":"s1","asOfSeq":7,"hasMore":false,"records":[
          {"type":"event","event":{"type":"system/message","seq":7,"time":1,
            "data":{"turn":1,"step":1,"message":{"role":"system","content":[
              {"type":"text","text":"You are an AI agent powered by DeepSeek Harness."}
            ]}}}}
        ]}
        """)
        #expect(result.conversationItems().isEmpty)
    }

    @Test("the prompt is paired with the turn it opens")
    func promptBeforeTurnStart() throws {
        // A page whose *oldest* record is the prompt: its `turn/start` is in the
        // page before this one, because a page is a window and the window can be
        // cut anywhere. The prompt carries no `data.turn` of its own, so the
        // record it is paired with is the only thing that can place it, and the
        // pairing is by order rather than by a number.
        //
        // Not the order the host writes *within* one page, which is the other way
        // round -- `turn/start` first, the prompt two records later, measured on
        // the live wire and in the durable log, and pinned by `RunningTurnTests`.
        // Both shapes have to work: this one is what a page edge produces, and it
        // is why the pairing cannot simply assume a turn is already open.
        let result = try page("""
        {"sessionId":"s1","asOfSeq":20,"hasMore":false,"records":[
          {"type":"event","event":{"type":"user/message","seq":1,"time":1000,
            "data":{"content":[{"type":"text","text":"anybody there?"}],"source":{"kind":"user"}}}},
          {"type":"event","event":{"type":"turn/start","seq":2,"time":1100,"data":{"turn":1}}},
          {"type":"event","event":{"type":"step/start","seq":3,"time":1200,"data":{"turn":1,"step":1}}}
        ]}
        """)
        let turn = try #require(result.conversationTurns().first)
        #expect(turn.prompts.count == 1)
        #expect(turn.stepCount == 1)
    }

    @Test("a whole exchange renders in order")
    func fullExchange() throws {
        // The end-to-end shape of what the user reported: several prompts and
        // the replies to them, in the order a log holds them.
        let result = try page("""
        {"sessionId":"s1","asOfSeq":32,"hasMore":false,"records":[
          {"type":"event","event":{"type":"user/message","seq":8,"time":1,
            "data":{"content":[{"type":"text","text":"你好"}],"source":{"kind":"user"}}}},
          {"type":"event","event":{"type":"assistant/message","seq":9,"time":2,
            "data":{"message":{"role":"assistant","content":[{"type":"text","text":"你好！有什么可以帮你的？"}]}}}},
          {"type":"event","event":{"type":"user/message","seq":10,"time":3,
            "data":{"content":[{"type":"text","text":"你是谁"}],"source":{"kind":"user"}}}},
          {"type":"event","event":{"type":"assistant/message","seq":11,"time":4,
            "data":{"message":{"role":"assistant","content":[{"type":"text","text":"我是一个编码 agent。"}]}}}}
        ]}
        """)
        let items = result.conversationItems()
        #expect(items.count == 4)
        let rendered = items.compactMap { item -> String? in
            if case .message(_, let role, let text, _) = item {
                return "\(role):\(text)"
            }
            return nil
        }
        #expect(rendered == [
            "user:你好",
            "assistant:你好！有什么可以帮你的？",
            "user:你是谁",
            "assistant:我是一个编码 agent。",
        ])
    }

    @Test("a real exchange renders in full")
    func realExchange() throws {
        // The prompts and replies below are copied verbatim out of a session log
        // on this machine, trimmed only of tool-call arguments. The key placement
        // is theirs, not mine: a user message keeps its parts at `data.content`,
        // and a message the model produced keeps them at `data.message.content`.
        //
        // That placement is what was wrong. Every reply was missing from the
        // phone while the computer showed the whole exchange, and no test caught it
        // because every fixture had been written to match the parser rather than
        // the host.
        let result = try page("""
        {"sessionId":"s1","asOfSeq":660,"hasMore":false,"records":[
          {"type":"event","event":{"type":"user/message","seq":336,"time":1791089283671,"data":{"content":[{"type":"text","text":"请开始修复。注意仍然保持目前良好的GUI与内核解耦状态"}],"source":{"kind":"user"},"role":"user"}}},
          {"type":"event","event":{"type":"assistant/message","seq":338,"time":1791089283672,"data":{"turn":1,"step":1,"message":{"role":"assistant","content":[{"type":"reasoning","text":""},{"type":"text","text":"I'll fix the four issues while preserving the C-ABI-only decoupling."}],"source":{"kind":"model","provider":"deepseek-account","model":"deepseek-flash"}}}}},
          {"type":"event","event":{"type":"user/message","seq":340,"time":1791089283673,"data":{"content":[{"type":"text","text":"允许你写入ISC-Core了"}],"source":{"kind":"user"},"role":"user"}}},
          {"type":"event","event":{"type":"assistant/message","seq":342,"time":1791089283674,"data":{"turn":1,"step":1,"message":{"role":"assistant","content":[{"type":"reasoning","text":""},{"type":"text","text":"Write access to ISC-Core is now available."}],"source":{"kind":"model","provider":"deepseek-account","model":"deepseek-flash"}}}}}
        ]}
        """)
        let rendered = result.conversationItems().compactMap { item -> String? in
            if case .message(_, let role, let text, _) = item { return "\(role):\(text)" }
            return nil
        }
        #expect(rendered == [
            "user:请开始修复。注意仍然保持目前良好的GUI与内核解耦状态",
            "assistant:I'll fix the four issues while preserving the C-ABI-only decoupling.",
            "user:允许你写入ISC-Core了",
            "assistant:Write access to ISC-Core is now available.",
        ])
    }

    @Test("a record written without the gateway wrapper is read the same way")
    func unwrappedRecord() throws {
        let result = try page("""
        {"sessionId":"s1","asOfSeq":30,"hasMore":false,"records":[
          {"type":"assistant/message","seq":29,"time":1791089307181,
           "data":{"message":{"role":"assistant","content":[{"type":"text","text":"unwrapped reply"}]}}}
        ]}
        """)
        guard case .message(_, let role, let text, _) = result.conversationItems().first else {
            Issue.record("expected a message from an unwrapped record")
            return
        }
        #expect(role == .assistant)
        #expect(text == "unwrapped reply")
    }
}

@Suite("Conversation cache")
struct ConversationCacheTests {
    private func item(_ id: String, _ text: String, at: Double) -> ConversationItem {
        .message(id: id, role: .user, text: text, at: Date(timeIntervalSince1970: at))
    }

    @Test("round-trips through a file, keeping order and roles")
    func roundTrip() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mizar-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let cache = FileConversationCache(directory: directory)
        let conversation = CachedConversation(
            sessionId: "session-1",
            items: [
                .message(id: "a", role: .user, text: "你好", at: Date(timeIntervalSince1970: 1)),
                .message(id: "b", role: .assistant, text: "reply", at: Date(timeIntervalSince1970: 2)),
                .failure(id: "c", message: "the turn ended", at: Date(timeIntervalSince1970: 3)),
            ],
            throughSeq: 42,
            hasMore: true,
        )
        await cache.save(conversation)

        let loaded = try #require(await cache.load(sessionId: "session-1"))
        #expect(loaded.items == conversation.items)
        #expect(loaded.throughSeq == 42)
        #expect(loaded.hasMore)
    }

    @Test("a turn's step count survives the cache")
    func stepCountRoundTrip() async throws {
        // The count is derived from `step/start` records, which are not items --
        // so it lives on the turn and nowhere else. A cache that drops it is a
        // conversation that reads "Completed in 12 s" with no idea whether the
        // turn took one step or eleven, and the count is the only part of a step
        // the transport still sends.
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mizar-turns-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        let cache = FileConversationCache(directory: directory)
        let stored = ConversationTurn(
            turn: 4,
            prompts: [.message(id: "seq-1", role: .user, text: "run it", at: Date(timeIntervalSince1970: 1))],
            steps: [.message(id: "seq-2", role: .assistant, text: "done", at: Date(timeIntervalSince1970: 2))],
            stepCount: 11,
            startedAt: Date(timeIntervalSince1970: 1),
            endedAt: Date(timeIntervalSince1970: 2),
            endedReason: "completed",
        )
        await cache.save(
            CachedConversation(
                sessionId: "session-1",
                items: [],
                throughSeq: 2,
                turns: [stored],
            ),
        )

        // A fresh cache object, as a relaunch would build.
        let read = try #require(await FileConversationCache(directory: directory).load(sessionId: "session-1"))
        let turn = try #require(read.turns?.first)
        #expect(turn == stored)
        #expect(turn.stepCount == 11)
    }

    @Test("a turn written before step counts existed still decodes")
    func turnWithoutStepCountDecodes() throws {
        // The cache is a file format and it outlives a build. A turn written by
        // the previous version has no `stepCount` key at all, and a turn that
        // fails to decode is a conversation that looks lost -- which is the one
        // thing this file exists to prevent.
        let json = """
        {"turn":3,"prompts":[],"steps":[],"startedAt":0,"endedAt":10,"endedReason":"completed"}
        """
        let decoder = JSONDecoder()
        let turn = try decoder.decode(ConversationTurn.self, from: Data(json.utf8))
        #expect(turn.turn == 3)
        #expect(turn.stepCount == nil)
    }

    @Test("merges by id rather than appending")
    func mergeById() {
        // The page and the cache overlap on every refresh, and concatenating
        // them duplicates everything they share.
        let cached = [item("a", "one", at: 1), item("b", "two", at: 2)]
        let fresh = [item("b", "two", at: 2), item("c", "three", at: 3)]
        let merged = mergeConversations(cached: cached, fresh: fresh)
        #expect(merged.count == 3)
        #expect(merged.map(\.id) == ["a", "b", "c"])
    }

    @Test("fresh wins when the same id changed")
    func freshWins() {
        let cached = [item("a", "old text", at: 1)]
        let fresh = [item("a", "new text", at: 1)]
        let merged = mergeConversations(cached: cached, fresh: fresh)
        guard case .message(_, _, let text, _) = merged.first else {
            Issue.record("expected a message")
            return
        }
        #expect(text == "new text")
    }

    @Test("records written in the same millisecond keep their log order")
    func tiesBreakBySeq() {
        // The scrambling. One prompt emits about eighteen records and runs of
        // them are written inside a single millisecond -- measured on a real
        // session, the first three records all carry `time: 1791089167121`. The
        // merge collected into a dictionary and sorted on the timestamp alone,
        // so those ties came out in whatever order the hash table offered, and
        // the same conversation ordered differently between one load and the
        // next. `seq` is the log's own strictly increasing counter and is what
        // settles them.
        let at = Date(timeIntervalSince1970: 1_791_089_167.121)
        let merged = mergeConversations(
            cached: [
                .message(id: "seq-12", role: .assistant, text: "third", at: at),
                .message(id: "seq-10", role: .user, text: "first", at: at),
            ],
            fresh: [.message(id: "seq-11", role: .assistant, text: "second", at: at)],
        )
        #expect(merged.map(\.id) == ["seq-10", "seq-11", "seq-12"])
    }

    @Test("the same merge repeated gives the same order")
    func mergeIsDeterministic() {
        // Dictionary iteration order varies between runs, so a comparison with
        // ties can put the same items in a different order every time. Ten runs
        // of the same input is what catches a comparator that leaves any.
        let at = Date(timeIntervalSince1970: 1_791_089_167.121)
        let items: [ConversationItem] = (0..<20).map {
            .message(id: "seq-\($0)", role: .assistant, text: "line \($0)", at: at)
        }
        let expected = (0..<20).map { "seq-\($0)" }
        for _ in 0..<10 {
            // Shuffled on the way in: the merge is not allowed to depend on the
            // order it is handed either.
            let merged = mergeConversations(cached: items.shuffled(), fresh: items.shuffled())
            #expect(merged.map(\.id) == expected)
        }
    }

    @Test("an item with no log position still sorts")
    func itemsWithoutSeqSort() {
        // Not every item carries a position -- the id shape is `seq-<n>` and
        // anything else has none. Those still have to land somewhere rather
        // than crashing or vanishing.
        let merged = mergeConversations(
            cached: [item("unknown", "no position", at: 2)],
            fresh: [.message(id: "seq-9", role: .user, text: "positioned", at: Date(timeIntervalSince1970: 1))],
        )
        #expect(merged.map(\.id) == ["seq-9", "unknown"])
    }

    /// A turn built from seq numbers, which is all the ordering reads.
    private func turn(
        _ number: Int?,
        prompts promptSeqs: [Int],
        steps stepSeqs: [Int],
        ended: String? = nil,
    ) -> ConversationTurn {
        ConversationTurn(
            turn: number,
            prompts: promptSeqs.map {
                .message(
                    id: "seq-\($0)",
                    role: .user,
                    text: "prompt \($0)",
                    at: Date(timeIntervalSince1970: TimeInterval($0)),
                )
            },
            steps: stepSeqs.map {
                .message(
                    id: "seq-\($0)",
                    role: .assistant,
                    text: "step \($0)",
                    at: Date(timeIntervalSince1970: TimeInterval($0)),
                )
            },
            startedAt: nil,
            endedAt: nil,
            endedReason: ended,
        )
    }

    @Test("a prompt stranded at a page edge goes back to its turn")
    func strandedPromptIsReclaimed() {
        // The shape read off a real session. `turn/start` for turn 78 is at seq
        // 9625 and the prompt that began it at 9628, so a page cut at 9629 holds
        // the prompt and nothing that claims it -- the prompt became its own
        // group, which then sorted to the end of the conversation, drawing a
        // message sent at 09:57 underneath one sent at 12:01.
        let stranded = turn(nil, prompts: [9628], steps: [])
        let turn78 = turn(78, prompts: [], steps: [9630, 9631])
        let turn79 = turn(79, prompts: [9800], steps: [9801])

        let merged = mergeTurns(cached: [stranded, turn78], fresh: [turn79])

        #expect(merged.map(\.turn) == [78, 79])
        #expect(merged.first?.prompts.map(\.id) == ["seq-9628"])
    }

    @Test("a group with no turn number sorts by position, not to the end")
    func unnumberedGroupSortsByPosition() {
        // The old comparator sorted on `turn ?? Int.max`, so anything the log did
        // not place was drawn after everything else no matter how old it was.
        let early = turn(nil, prompts: [10], steps: [])
        // Given its own prompt, so it is not a candidate for reclaiming and the
        // ordering is what is under test.
        let late = turn(5, prompts: [50], steps: [51])

        let merged = mergeTurns(cached: [], fresh: [late, early])

        #expect(merged.first?.prompts.map(\.id) == ["seq-10"])
    }

    @Test("two unnumbered groups do not collapse into one")
    func unnumberedGroupsStayDistinct() {
        // Every group without a number used to be identified as "unopened", and
        // the merge is a dictionary keyed on that -- so all of them but the last
        // were overwritten and their prompts disappeared.
        let first = turn(nil, prompts: [10], steps: [])
        let second = turn(nil, prompts: [20], steps: [])

        let merged = mergeTurns(cached: [], fresh: [first, second])

        #expect(merged.count == 2)
        #expect(merged.flatMap(\.prompts).map(\.id) == ["seq-10", "seq-20"])
    }

    @Test("a turn the agent continued on its own is not a second turn")
    func continuationsCollapse() {
        // Read off a real session: long runs of consecutive `turn/start` with no
        // `user/message` between them -- turn 2 into 3 into 4 into 5, later 29
        // into 30 into 31 into 32. The screen drew each as its own "已完成" bar,
        // so one instruction came back as two finished turns stacked under one
        // message.
        let asked = turn(2, prompts: [100], steps: [101], ended: "completed")
        let carriedOn = turn(3, prompts: [], steps: [200, 201], ended: "completed")
        let andOn = turn(4, prompts: [], steps: [300], ended: "completed")

        let merged = mergeTurns(cached: [], fresh: [asked, carriedOn, andOn])

        #expect(merged.count == 1, "the continuation is its own turn again")
        #expect(merged.first?.prompts.map(\.id) == ["seq-100"])
        #expect(merged.first?.steps.map(\.id) == ["seq-101", "seq-200", "seq-201", "seq-300"])
    }

    @Test("a turn with its own prompt is never absorbed")
    func promptedTurnsSurvive() {
        // The collapse keys on the *absence* of a prompt. Two instructions in a
        // row are two turns, however quickly they follow each other.
        let first = turn(7, prompts: [10], steps: [11], ended: "completed")
        let second = turn(8, prompts: [20], steps: [21], ended: "completed")

        let merged = mergeTurns(cached: [], fresh: [first, second])

        #expect(merged.count == 2)
        #expect(merged.map(\.turn) == [7, 8])
    }

    @Test("a turn that straddles the page window keeps its prompt")
    func windowedTurnKeepsItsPrompt() {
        // The host trims a page to the newest few hundred messages, so the turn
        // crossing the window's oldest edge comes back **without the prompt that
        // began it**. Replacing the stored turn with that copy deleted the
        // operator's own message from the conversation -- and from the screen,
        // because the view draws turns and the turn no longer held it. Nothing
        // they could do on the phone brought it back.
        let stored = turn(78, prompts: [9628], steps: [9630])
        let windowed = turn(78, prompts: [], steps: [9700])

        let merged = mergeTurns(cached: [stored], fresh: [windowed])

        #expect(merged.count == 1)
        #expect(merged.first?.prompts.map(\.id) == ["seq-9628"])
        #expect(merged.first?.steps.map(\.id) == ["seq-9630", "seq-9700"])
    }

    @Test("merging the same two pages twice does not duplicate anything")
    func mergeIsIdempotent() {
        // `collapseContinuations` folds a chain that the host sends unfurled
        // again on the next page, so a turn's steps arrive both inside the
        // folded turn and beside it. Concatenating showed them twice.
        let asked = turn(2, prompts: [100], steps: [101], ended: "completed")
        let carriedOn = turn(3, prompts: [], steps: [200], ended: "completed")
        let once = mergeTurns(cached: [], fresh: [asked, carriedOn])
        let twice = mergeTurns(cached: once, fresh: [asked, carriedOn])

        #expect(twice.count == 1)
        #expect(twice.first?.steps.map(\.id) == once.first?.steps.map(\.id))
    }

    @Test("a turn the operator cancelled is not a completed one")
    func cancelledThenContinued() {
        // Only `error` counted as unfinished, so a turn that was cancelled --
        // and then carried on by a turn that completed -- reported "已完成" with
        // the abort folded away behind the bar. The continuation shape is the
        // real one: DSH emits consecutive `turn/start` with no user-authored
        // message between them.
        for kind in ["aborted", "blocked", "interrupted", "max-tokens"] {
            // Built by hand rather than through the helper: these need real
            // start and end times, and the helper deliberately leaves them out.
            let asked = ConversationTurn(
                turn: 5,
                prompts: [.message(id: "seq-10", role: .user, text: "go", at: Date(timeIntervalSince1970: 10))],
                steps: [.message(id: "seq-11", role: .assistant, text: "half", at: Date(timeIntervalSince1970: 11))],
                startedAt: Date(timeIntervalSince1970: 10),
                endedAt: Date(timeIntervalSince1970: 20),
                endedReason: kind,
            )
            let carriedOn = ConversationTurn(
                turn: 6,
                prompts: [],
                steps: [.message(id: "seq-20", role: .assistant, text: "the rest", at: Date(timeIntervalSince1970: 21))],
                startedAt: Date(timeIntervalSince1970: 21),
                endedAt: Date(timeIntervalSince1970: 30),
                endedReason: "completed",
            )

            let merged = mergeTurns(cached: [], fresh: [asked, carriedOn])

            #expect(merged.count == 1)
            #expect(
                merged.first?.failed == true,
                "a turn that ended '\(kind)' and was continued is reported as finished",
            )
            // The first unfinished reason is kept, not flattened to `error`:
            // "the operator cancelled this" and "it hit an error" are different
            // things to be told.
            #expect(merged.first?.endedReason == kind)
            #expect(merged.first?.isRunning == false)
        }
    }

    @Test("a continuation that failed makes the whole turn failed")
    func continuationFailurePropagates() {
        // "completed" then "error" is a failed turn: the operator needs to see
        // that the work they asked for did not finish, not that the first part
        // of it did.
        let asked = turn(2, prompts: [100], steps: [101], ended: "completed")
        let carriedOn = turn(3, prompts: [], steps: [200], ended: "error")

        let merged = mergeTurns(cached: [], fresh: [asked, carriedOn])

        #expect(merged.count == 1)
        #expect(merged.first?.failed == true)
    }

    @Test("a failure is not cancelled out by a continuation that finished")
    func continuationFailureIsNotOverwritten() {
        // The other order, and the one that bit. A turn fails, the agent
        // continues, the continuation completes. Taking the later reason made
        // the whole thing report "completed", which folded the failure behind
        // the summary bar -- so the one state an operator must see was the one
        // the fold could hide.
        let asked = turn(2, prompts: [100], steps: [101], ended: "error")
        let carriedOn = turn(3, prompts: [], steps: [200], ended: "completed")

        let merged = mergeTurns(cached: [], fresh: [asked, carriedOn])

        #expect(merged.count == 1)
        #expect(merged.first?.failed == true)
    }

    @Test("the usage frame survives a restart")
    func statsRoundTrip() async throws {
        // The figures above the composer are read from the cache before the
        // network is asked, so a frame that does not survive being written is a
        // model name and a context percentage that vanish on the next launch --
        // reported as the figures appearing and disappearing between visits.
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mizar-stats-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }

        // A fresh cache object, as a relaunch would build.
        let written = FileConversationCache(directory: directory)
        await written.save(
            CachedConversation(
                sessionId: "session-1",
                items: [],
                throughSeq: 12,
                stats: SessionStatsFrame(
                    tokenUsage: TokenUsage(
                        uncachedInputTokens: 12_480,
                        outputTokens: 3_712,
                        cacheReadTokens: 180_320,
                        cacheWriteTokens: 4_096,
                        billedInputTokens: 196_896,
                    ),
                    cacheHit: CacheHit(ratio: 0.92, displayPercent: "92"),
                    context: ContextPressure(
                        window: 128_000,
                        pressureTokens: 41_000,
                        projectedTokens: 44_500,
                        percent: 35,
                        breakdown: ContextBreakdown(systemTokens: 1_455, toolsTokens: 5_157, messageTokens: 34_388),
                    ),
                    stats: nil,
                    model: ModelSelectionPair(
                        lastUsed: ModelSelection(provider: "deepseek-official", model: "deepseek-flash", reasoningEffort: "high"),
                        next: nil,
                    ),
                    permissionPreset: "workspace-write",
                    title: "Mock session",
                ),
            ),
        )

        let read = try #require(await FileConversationCache(directory: directory).load(sessionId: "session-1"))
        #expect(read.stats?.context?.percent == 35)
        #expect(read.stats?.model?.lastUsed?.model == "deepseek-flash")
        #expect(read.stats?.model?.lastUsed?.reasoningEffort == "high")
    }

    @Test("a session id that could escape the directory does not")
    func safeFileNames() async {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mizar-cache-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = FileConversationCache(directory: directory)
        // Session ids come over the wire; a path built from unvalidated input is
        // how a cache becomes a directory traversal.
        await cache.save(CachedConversation(sessionId: "../../etc/passwd", items: [], throughSeq: nil))
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        #expect(files.count == 1)
        #expect(!files[0].contains("/"))
    }
}











@Suite("Turns")
struct TurnTests {
    /// A turn as the log holds it: prompts, then the steps the agent took.
    private func page(_ payload: String) throws -> SessionMessagesResult {
        try JSONDecoder().decode(SessionMessagesResult.self, from: Data(payload.utf8))
    }

    @Test("a turn's records are grouped, and its prompt is not")
    func grouping() throws {
        // The shape that made the model look like it was talking to itself: one
        // prompt, three steps, and a reader with no idea they belonged together.
        // Every record carries `data.turn`; that is what does the grouping.
        let result = try page("""
        {"sessionId":"s1","asOfSeq":20,"hasMore":false,"records":[
          {"type":"event","event":{"type":"turn/start","seq":1,"time":1000,"data":{"turn":1}}},
          {"type":"event","event":{"type":"user/message","seq":2,"time":1100,
            "data":{"content":[{"type":"text","text":"fix the parser"}],"source":{"kind":"user"}}}},
          {"type":"event","event":{"type":"step/start","seq":3,"time":1200,"data":{"turn":1,"step":1}}},
          {"type":"event","event":{"type":"assistant/message","seq":4,"time":1300,
            "data":{"turn":1,"step":1,"message":{"role":"assistant","content":[{"type":"text","text":"Looking at it."}]}}}},
          {"type":"event","event":{"type":"step/end","seq":5,"time":1400,"data":{"turn":1,"step":1}}},
          {"type":"event","event":{"type":"assistant/message","seq":6,"time":1500,
            "data":{"turn":1,"step":2,"message":{"role":"assistant","content":[{"type":"text","text":"Found it."}]}}}},
          {"type":"event","event":{"type":"assistant/message","seq":7,"time":1600,
            "data":{"turn":1,"step":3,"message":{"role":"assistant","content":[{"type":"text","text":"Fixed."}]}}}},
          {"type":"event","event":{"type":"turn/end","seq":8,"time":2000,
            "data":{"turn":1,"reason":{"kind":"completed"}}}}
        ]}
        """)
        let turns = result.conversationTurns()
        #expect(turns.count == 1)
        let turn = try #require(turns.first)
        // The prompt stays out of the agent's own records: it is what the
        // operator typed.
        #expect(turn.prompts.count == 1)
        #expect(turn.steps.count == 3)
        #expect(turn.duration == 1)
        #expect(!turn.failed)
        // Counted from the one `step/start` marker, not from the three messages:
        // the two differ because this fixture is an old full-fidelity log, and
        // under summary-only history the same turn arrives as one marker per step
        // and a single message. The marker is what the count follows, so a log
        // that carries both still reports what the log said.
        #expect(turn.stepCount == 1)
    }

    @Test("the step count follows the markers, not the messages")
    func stepCountFollowsMarkers() throws {
        // The shape the host actually sends now, and the reason `stepCount`
        // exists at all: eleven steps used to arrive as eleven messages and now
        // arrive as eleven tiny `step/start` markers and **one**
        // `assistant/message` -- the model's summary of the turn. Counting the
        // messages would draw "1 steps" over a turn that took eleven.
        let result = try page("""
        {"sessionId":"s1","asOfSeq":20,"hasMore":false,"records":[
          {"type":"event","event":{"type":"turn/start","seq":1,"time":1000,"data":{"turn":1}}},
          {"type":"event","event":{"type":"user/message","seq":2,"time":1100,
            "data":{"content":[{"type":"text","text":"fix the parser"}],"source":{"kind":"user"}}}},
          {"type":"event","event":{"type":"step/start","seq":3,"time":1200,"data":{"turn":1,"step":1}}},
          {"type":"event","event":{"type":"step/start","seq":4,"time":1300,"data":{"turn":1,"step":2}}},
          {"type":"event","event":{"type":"step/start","seq":5,"time":1400,"data":{"turn":1,"step":3}}},
          {"type":"event","event":{"type":"assistant/message","seq":6,"time":1500,
            "data":{"turn":1,"step":3,"message":{"role":"assistant","content":[
              {"type":"text","text":"Three files changed."}]}}}},
          {"type":"event","event":{"type":"turn/end","seq":7,"time":2000,
            "data":{"turn":1,"reason":{"kind":"completed"}}}}
        ]}
        """)
        let turn = try #require(result.conversationTurns().first)
        #expect(turn.stepCount == 3)
        #expect(turn.steps.count == 1)
        // And the answer is the message, not a marker.
        guard case .message(_, .assistant, let text, _) = turn.steps.first else {
            Issue.record("expected the turn's answer, got \(turn.steps)")
            return
        }
        #expect(text == "Three files changed.")
    }

    @Test("a running turn has steps counted and no answer at all")
    func runningTurnHasNoAnswer() throws {
        // The transport sends nothing for a turn still going: no `assistant
        // /message`, because a half-written answer is not the turn's summary.
        // The row therefore has a count to show and nothing to draw under it,
        // and neither of those is invented here.
        //
        // The records are in the order the host writes them, which this fixture
        // used to get backwards: `turn/start` first, then the markers, and the
        // operator's prompt **after** them, carrying no turn of its own. Read off
        // the durable log of a real session (`turn/start` seq 4, `step/start` 6,
        // the prompt 8) and confirmed on the live wire. With the prompt written
        // first, this test passed while the screen dropped the prompt entirely --
        // a running turn has no `assistant/message` to claim it with, so a reader
        // that only pairs a prompt with a *later* `turn/start` left the turn that
        // was executing with none.
        let result = try page("""
        {"sessionId":"s1","asOfSeq":20,"hasMore":false,"records":[
          {"type":"event","event":{"type":"turn/start","seq":1,"time":1000,"data":{"turn":1}}},
          {"type":"event","event":{"type":"step/start","seq":2,"time":1100,"data":{"turn":1,"step":1}}},
          {"type":"event","event":{"type":"user/message","seq":3,"time":1200,
            "data":{"content":[{"type":"text","text":"run the suite"}],"source":{"kind":"user"}}}},
          {"type":"event","event":{"type":"step/start","seq":4,"time":1300,"data":{"turn":1,"step":2}}}
        ]}
        """)
        let turn = try #require(result.conversationTurns().first)
        #expect(turn.isRunning)
        #expect(turn.stepCount == 2)
        #expect(turn.steps.isEmpty)
        // The prompt is still there: a running turn is opened to read what was
        // asked, not what was answered.
        #expect(turn.prompts.count == 1)
    }

    @Test("a turn whose markers were trimmed away has no count, not a zero")
    func missingMarkersHaveNoCount() throws {
        // A page can be cut across a turn, and the host trims it -- so a turn
        // can arrive with its prompt and its end and none of the markers in
        // between. Zero would be a claim about the turn; `nil` is what "the log
        // did not say" actually is, and the view draws no number for it.
        let result = try page("""
        {"sessionId":"s1","asOfSeq":20,"hasMore":false,"records":[
          {"type":"event","event":{"type":"turn/start","seq":1,"time":1000,"data":{"turn":1}}},
          {"type":"event","event":{"type":"user/message","seq":2,"time":1100,
            "data":{"content":[{"type":"text","text":"carry on"}],"source":{"kind":"user"}}}},
          {"type":"event","event":{"type":"turn/end","seq":3,"time":2000,
            "data":{"turn":1,"reason":{"kind":"completed"}}}}
        ]}
        """)
        let turn = try #require(result.conversationTurns().first)
        #expect(turn.stepCount == nil)
    }

    @Test("a turn that ended badly with nothing to show is drawn as a failure")
    func failureWithNoAnswer() throws {
        // The shape the mock host serves and the real host produces without a
        // provider credential: a turn with markers, a turn/end saying `error`,
        // and **no message at all**. Under the old transport a streaming attempt
        // carried the reason; summary-only history sends no attempt, so a reader
        // that only looked at messages would draw a bare "未完成" bar over an
        // empty screen and leave the operator to guess.
        let result = try page("""
        {"sessionId":"s1","asOfSeq":9,"hasMore":false,"records":[
          {"type":"event","event":{"type":"turn/start","seq":1,"time":1000,"data":{"turn":1}}},
          {"type":"event","event":{"type":"turn/end","seq":2,"time":4000,
            "data":{"turn":1,"reason":{"kind":"error","error":{"message":"no API key"}}}}}
        ]}
        """)
        let turn = try #require(result.conversationTurns().first)
        #expect(turn.failed)
        guard case .failure(_, let message, _) = turn.steps.first else {
            Issue.record("a turn that produced nothing was not drawn as a failure: \(turn.steps)")
            return
        }
        // The host's own words when it gave them, rather than a paraphrase.
        #expect(message == "no API key")
        // No marker was sent for it, so there is no count -- and none is
        // invented. A missing record is not a zero.
        #expect(turn.stepCount == nil)
    }

    @Test("a turn that failed after answering is not drawn as having said nothing")
    func failureWithAnAnswer() throws {
        // The other side of the rule. A turn that answered and *then* failed has
        // said something, and a failure card over the answer would be a worse
        // lie than the warning on the row -- which is already there, because the
        // reason is not `completed`.
        let result = try page("""
        {"sessionId":"s1","asOfSeq":9,"hasMore":false,"records":[
          {"type":"event","event":{"type":"turn/start","seq":1,"time":1000,"data":{"turn":1}}},
          {"type":"event","event":{"type":"assistant/message","seq":2,"time":1200,
            "data":{"turn":1,"step":1,"message":{"role":"assistant","content":[
              {"type":"text","text":"I changed two files."}]}}}},
          {"type":"event","event":{"type":"turn/end","seq":3,"time":4000,
            "data":{"turn":1,"reason":{"kind":"aborted"}}}}
        ]}
        """)
        let turn = try #require(result.conversationTurns().first)
        #expect(turn.failed)
        #expect(turn.steps.count == 1)
        guard case .message(_, _, let text, _) = turn.steps.first else {
            Issue.record("the answer was replaced by a failure card: \(turn.steps)")
            return
        }
        #expect(text == "I changed two files.")
    }

    @Test("a completed turn is not drawn as a failure")
    func completedTurnHasNoFailureItem() throws {
        // The guard on the rule above: only a reason that is not `completed`
        // produces the card, so an ordinary turn cannot acquire one.
        let result = try page("""
        {"sessionId":"s1","asOfSeq":9,"hasMore":false,"records":[
          {"type":"event","event":{"type":"turn/start","seq":1,"time":1000,"data":{"turn":1}}},
          {"type":"event","event":{"type":"turn/end","seq":2,"time":4000,
            "data":{"turn":1,"reason":{"kind":"completed"}}}}
        ]}
        """)
        let turn = try #require(result.conversationTurns().first)
        #expect(!turn.failed)
        #expect(turn.steps.isEmpty)
    }

    @Test("a cancelled turn is not a completed one")
    func abortedIsNotCompleted() throws {
        // `turn/end.reason.kind` is `completed` only when the agent finished. A
        // cancelled turn, a blocked one and one that ran out of context all end
        // with their own kind -- and treating anything but `error` as success
        // drew "已完成" over work that stopped halfway.
        for kind in ["aborted", "blocked", "max-tokens", "interrupted", "forked", "something-new"] {
            let result = try page("""
            {"sessionId":"s1","asOfSeq":9,"hasMore":false,"records":[
              {"type":"event","event":{"type":"turn/start","seq":1,"time":1000,"data":{"turn":1}}},
              {"type":"event","event":{"type":"assistant/message","seq":2,"time":1200,
                "data":{"turn":1,"step":1,"message":{"role":"assistant","content":[{"type":"text","text":"one"}]}}}},
              {"type":"event","event":{"type":"assistant/message","seq":3,"time":1300,
                "data":{"turn":1,"step":2,"message":{"role":"assistant","content":[{"type":"text","text":"two"}]}}}},
              {"type":"event","event":{"type":"turn/end","seq":4,"time":4000,
                "data":{"turn":1,"reason":{"kind":"\(kind)"}}}}
            ]}
            """)
            let turn = try #require(result.conversationTurns().first)
            #expect(turn.failed, "a turn that ended '\(kind)' is reported as finished")
            #expect(!turn.isRunning, "a turn with an end record is still running")
        }
    }

    @Test("a finished turn's answer is in the turn, with nothing to open")
    func answerIsInTheTurn() throws {
        // Hiding the answer behind a tap gained nothing, and there is no longer
        // anything to hide it behind: the transport sends one message per
        // finished turn. The turn's own records have to hold it, because the
        // view draws what the turn holds and nothing else.
        let result = try page("""
        {"sessionId":"s1","asOfSeq":9,"hasMore":false,"records":[
          {"type":"event","event":{"type":"turn/start","seq":1,"time":1000,"data":{"turn":1}}},
          {"type":"event","event":{"type":"user/message","seq":2,"time":1100,
            "data":{"content":[{"type":"text","text":"hello"}],"source":{"kind":"user"}}}},
          {"type":"event","event":{"type":"assistant/message","seq":3,"time":1200,
            "data":{"turn":1,"step":1,"message":{"role":"assistant","content":[{"type":"text","text":"hi"}]}}}}
        ]}
        """)
        let turn = try #require(result.conversationTurns().first)
        guard case .message(_, .assistant, let text, _) = turn.steps.first else {
            Issue.record("the turn's answer is not in the turn: \(turn.steps)")
            return
        }
        #expect(text == "hi")
    }

    @Test("a failed turn says so")
    func failure() throws {
        let result = try page("""
        {"sessionId":"s1","asOfSeq":9,"hasMore":false,"records":[
          {"type":"event","event":{"type":"turn/start","seq":1,"time":1000,"data":{"turn":1}}},
          {"type":"event","event":{"type":"turn/end","seq":2,"time":5000,
            "data":{"turn":1,"reason":{"kind":"error","error":{"message":"no API key"}}}}}
        ]}
        """)
        let turn = try #require(result.conversationTurns().first)
        #expect(turn.failed)
        #expect(turn.duration == 4)
    }

    @Test("several turns stay in order")
    func ordering() throws {
        let result = try page("""
        {"sessionId":"s1","asOfSeq":9,"hasMore":false,"records":[
          {"type":"event","event":{"type":"turn/start","seq":1,"time":1000,"data":{"turn":1}}},
          {"type":"event","event":{"type":"assistant/message","seq":2,"time":1100,
            "data":{"turn":1,"step":1,"message":{"role":"assistant","content":[{"type":"text","text":"one"}]}}}},
          {"type":"event","event":{"type":"turn/start","seq":3,"time":2000,"data":{"turn":2}}},
          {"type":"event","event":{"type":"assistant/message","seq":4,"time":2100,
            "data":{"turn":2,"step":1,"message":{"role":"assistant","content":[{"type":"text","text":"two"}]}}}}
        ]}
        """)
        #expect(result.conversationTurns().map(\.turn) == [1, 2])
    }

    @Test("a turn with no end is running, not finished")
    func runningTurn() throws {
        // The reported bug. A turn that is still working has no `turn/end`, and
        // the reader invented an end time from the last record it held -- so a
        // live turn was drawn as "已完成，用时 1 分 12 秒", with the seconds
        // measuring the age of the newest message rather than any work.
        let result = try page("""
        {"sessionId":"s1","asOfSeq":9,"hasMore":false,"records":[
          {"type":"event","event":{"type":"turn/start","seq":1,"time":1000,"data":{"turn":1}}},
          {"type":"event","event":{"type":"user/message","seq":2,"time":1100,
            "data":{"content":[{"type":"text","text":"refactor it"}],"source":{"kind":"user"}}}},
          {"type":"event","event":{"type":"assistant/message","seq":3,"time":5000,
            "data":{"turn":1,"step":1,"message":{"role":"assistant","content":[{"type":"text","text":"Halfway"}]}}}}
        ]}
        """)
        let turn = try #require(result.conversationTurns().first)
        #expect(turn.isRunning)
        // No duration: there is nothing that can have taken one yet.
        #expect(turn.duration == nil)
        // The elapsed time is still answerable, and it is measured from the
        // turn's own start rather than from the message that happens to be last.
        #expect(turn.elapsed(asOf: Date(timeIntervalSince1970: 20)) == 19)
    }

    @Test("an ended turn is not running")
    func endedTurnIsNotRunning() throws {
        let result = try page("""
        {"sessionId":"s1","asOfSeq":9,"hasMore":false,"records":[
          {"type":"event","event":{"type":"turn/start","seq":1,"time":1000,"data":{"turn":1}}},
          {"type":"event","event":{"type":"assistant/message","seq":2,"time":1200,
            "data":{"turn":1,"step":1,"message":{"role":"assistant","content":[{"type":"text","text":"done"}]}}}},
          {"type":"event","event":{"type":"turn/end","seq":3,"time":4000,
            "data":{"turn":1,"reason":{"kind":"completed"}}}}
        ]}
        """)
        let turn = try #require(result.conversationTurns().first)
        #expect(!turn.isRunning)
        // A clock far past the end does not extend a finished turn.
        #expect(turn.elapsed(asOf: Date(timeIntervalSince1970: 9000)) == 3)
    }

    @Test("a prompt whose turn never started is not work in progress")
    func unstartedPromptIsNotRunning() throws {
        // A page edge: the prompt is the oldest record the page holds and the
        // `turn/start` that claims it is in the page before -- or the session
        // ended before the turn ever opened. Nothing here says an agent is
        // working, and drawing it as "正在处理" would claim one was thinking about
        // a message that may be the last thing anybody ever said.
        let result = try page("""
        {"sessionId":"s1","asOfSeq":9,"hasMore":false,"records":[
          {"type":"event","event":{"type":"user/message","seq":1,"time":1000,
            "data":{"content":[{"type":"text","text":"anybody there?"}],"source":{"kind":"user"}}}}
        ]}
        """)
        let turn = try #require(result.conversationTurns().first)
        #expect(turn.turn == nil)
        #expect(!turn.isRunning)
        // Nothing about it is a step count either: there is no turn to have
        // taken one.
        #expect(turn.stepCount == nil)
    }

    @Test("records a host did not number cannot give two rows one identity")
    func unnumberedRecordsKeepDistinctIdentities() throws {
        // A host that numbers nothing -- `seq` absent from every record -- gives
        // every record of a kind the same fallback id, `unknown-<type>`. And one
        // prompt really can arrive as two `user/message` records, the RPC source
        // and the inbox splice. Two rows sharing one id in a `ForEach` is a
        // crash rather than a drawing mistake, so the second of two colliding
        // ids is dropped as it is placed on its turn.
        let result = try page("""
        {"sessionId":"s1","asOfSeq":null,"hasMore":false,"records":[
          {"type":"event","event":{"type":"turn/start","time":1000,"data":{"turn":1}}},
          {"type":"event","event":{"type":"user/message","time":1100,
            "data":{"content":[{"type":"text","text":"fix the parser"}],"source":{"kind":"user"}}}},
          {"type":"event","event":{"type":"user/message","time":1150,
            "data":{"content":[{"type":"text","text":"fix the parser"}],"source":{"kind":"user"}}}},
          {"type":"event","event":{"type":"turn/end","time":2000,
            "data":{"turn":1,"reason":{"kind":"completed"}}}}
        ]}
        """)
        let turn = try #require(result.conversationTurns().first)
        let ids = turn.prompts.map(\.id)
        #expect(ids.count == Set(ids).count)
        #expect(ids.count == 1)
    }

    @Test("the duplicate rule is scoped to one turn, never across turns")
    func unnumberedPromptsSurviveOnTheirOwnTurns() throws {
        // The opposite direction, and the reason the dedup is per turn: on a
        // host that numbers nothing, two different turns' prompts both carry the
        // fallback id. Deduping page-wide would drop the second turn's prompt --
        // a message the operator typed, gone. The screen keys each turn's list
        // separately, so only a repeat *within* one list is a crash.
        let result = try page("""
        {"sessionId":"s1","asOfSeq":null,"hasMore":false,"records":[
          {"type":"event","event":{"type":"turn/start","time":1000,"data":{"turn":1}}},
          {"type":"event","event":{"type":"user/message","time":1100,
            "data":{"content":[{"type":"text","text":"first turn"}],"source":{"kind":"user"}}}},
          {"type":"event","event":{"type":"turn/end","time":1200,
            "data":{"turn":1,"reason":{"kind":"completed"}}}},
          {"type":"event","event":{"type":"turn/start","time":2000,"data":{"turn":2}}},
          {"type":"event","event":{"type":"user/message","time":2100,
            "data":{"content":[{"type":"text","text":"second turn"}],"source":{"kind":"user"}}}}
        ]}
        """)
        let turns = result.conversationTurns()
        #expect(turns.count == 2)
        #expect(turns.allSatisfy { $0.prompts.count == 1 })
        #expect(turns.flatMap { $0.prompts }.map { $0.words ?? "" } == ["first turn", "second turn"])
    }
}

@Suite("Turn merging")
struct TurnMergeTests {
    private func turn(_ n: Int?, _ text: String) -> ConversationTurn {
        ConversationTurn(
            turn: n,
            prompts: [],
            steps: [.message(id: "t\(n ?? -1)", role: .assistant, text: text, at: Date(timeIntervalSince1970: Double(n ?? 0)))],
            startedAt: nil,
            endedAt: nil,
            endedReason: nil,
        )
    }

    @Test("overlapping pages do not duplicate turns")
    func noDuplicates() {
        // Consecutive pages overlap, and appending one to the other would double
        // every turn they share.
        let merged = mergeTurns(cached: [turn(1, "one"), turn(2, "two")], fresh: [turn(2, "two"), turn(3, "three")])
        #expect(merged.map(\.turn) == [1, 2, 3])
    }

    @Test("the fresh page wins")
    func freshWins() {
        let merged = mergeTurns(cached: [turn(1, "old")], fresh: [turn(1, "new")])
        guard case .message(_, _, let text, _) = merged.first?.steps.first else {
            Issue.record("expected a step")
            return
        }
        #expect(text == "new")
    }

    @Test("a turn with no number sorts last, not first")
    func unnumberedLast() {
        // "Unknown" is not "earliest".
        let merged = mergeTurns(cached: [turn(1, "one")], fresh: [turn(nil, "loose")])
        #expect(merged.map(\.turn) == [1, nil])
    }

    /// A turn with an end time, so "finished" can be distinguished from "still going".
    private func ended(_ n: Int, at seconds: Double) -> ConversationTurn {
        ConversationTurn(
            turn: n,
            prompts: [],
            steps: [.message(id: "t\(n)", role: .assistant, text: "done", at: Date(timeIntervalSince1970: 0))],
            startedAt: Date(timeIntervalSince1970: 0),
            endedAt: Date(timeIntervalSince1970: seconds),
            endedReason: "completed",
        )
    }

    @Test("an older page cannot un-end a turn")
    func olderPageCannotRestartATurn() {
        // `loadOlder` passes the *older* page as `fresh`. With plain
        // "fresh wins", the copy of a turn that straddled the page boundary --
        // the one without its `turn/end`, because that record is in the newer
        // page -- replaced the copy that had it. Harmless while an end time was
        // invented from the last step; a turn that flipped back to "正在处理"
        // every time the operator scrolled up once it stopped being invented.
        let merged = mergeTurns(cached: [ended(7, at: 60)], fresh: [turn(7, "still going")])
        #expect(merged.count == 1)
        #expect(merged.first?.endedAt != nil)
        #expect(merged.first?.isRunning == false)
    }

    @Test("a page that knows the turn ended wins over one that does not")
    func newerPageEndsTheTurn() {
        // The other direction, which is the ordinary path: the turn finished
        // between two refreshes and the newer page carries its end.
        let merged = mergeTurns(cached: [turn(7, "still going")], fresh: [ended(7, at: 60)])
        #expect(merged.first?.endedAt != nil)
        #expect(merged.first?.isRunning == false)
    }

    /// A turn with a step count, and nothing else that matters here.
    private func counted(_ n: Int, steps: Int?) -> ConversationTurn {
        ConversationTurn(
            turn: n,
            prompts: [],
            steps: [],
            stepCount: steps,
            startedAt: nil,
            endedAt: nil,
            endedReason: nil,
        )
    }

    @Test("merging one turn's two copies does not add its step count twice")
    func stepCountIsNotDoubledByAMerge() {
        // The page and the cache overlap on every refresh, and they hold the
        // same steps. Adding the two counts would report a turn of eleven steps
        // as twenty-two after one pull-to-refresh and thirty-three after the
        // next -- a number that grows every time the screen is looked at.
        let merged = mergeTurns(cached: [counted(7, steps: 11)], fresh: [counted(7, steps: 11)])
        #expect(merged.first?.stepCount == 11)
    }

    @Test("the copy that saw more steps keeps its count")
    func theLargerCountWins() {
        // A page is a window, so one copy of a turn can arrive with fewer
        // markers than the other. The larger is the read that saw more of the
        // turn, in either direction, and the count cannot come back down.
        let windowed = mergeTurns(cached: [counted(7, steps: 3)], fresh: [counted(7, steps: 11)])
        #expect(windowed.first?.stepCount == 11)
        let other = mergeTurns(cached: [counted(7, steps: 11)], fresh: [counted(7, steps: 3)])
        #expect(other.first?.stepCount == 11)
    }

    @Test("a count on one copy and none on the other keeps the count")
    func aCountSurvivesAPageWithoutOne() {
        // A turn written before step counts existed has no count, and it merges
        // with a page that does on every refresh after the upgrade. Losing the
        // count to the older copy is the number disappearing from a row the
        // operator was just reading.
        let merged = mergeTurns(cached: [counted(7, steps: nil)], fresh: [counted(7, steps: 4)])
        #expect(merged.first?.stepCount == 4)
    }

    @Test("a continuation's steps are added to the turn it continued")
    func continuationStepsAreAdded() {
        // Opposite rule, and for the opposite reason: these are two *different*
        // turns folded into one, each with its own markers. Taking the larger
        // would report the first turn's steps and forget the rest of the work.
        let asked = ConversationTurn(
            turn: 2,
            prompts: [.message(id: "seq-100", role: .user, text: "go", at: Date(timeIntervalSince1970: 0))],
            steps: [],
            stepCount: 3,
            startedAt: Date(timeIntervalSince1970: 0),
            endedAt: Date(timeIntervalSince1970: 10),
            endedReason: "completed",
        )
        let carriedOn = ConversationTurn(
            turn: 3,
            prompts: [],
            steps: [],
            stepCount: 4,
            startedAt: Date(timeIntervalSince1970: 11),
            endedAt: Date(timeIntervalSince1970: 20),
            endedReason: "completed",
        )

        let merged = mergeTurns(cached: [], fresh: [asked, carriedOn])

        #expect(merged.count == 1)
        #expect(merged.first?.stepCount == 7)
    }
}


@Suite("Turn ordering")
struct TurnOrderingTests {
    private func page(_ payload: String) throws -> SessionMessagesResult {
        try JSONDecoder().decode(SessionMessagesResult.self, from: Data(payload.utf8))
    }

    @Test("a mid-turn steer keeps its place between two answers")
    func steeringStaysInline() throws {
        let result = try page("""
        {"sessionId":"s1","asOfSeq":6,"hasMore":false,"records":[
          {"type":"event","event":{"type":"turn/start","seq":1,"time":1000,"data":{"turn":1}}},
          {"type":"event","event":{"type":"user/message","seq":2,"time":1100,
            "data":{"content":[{"type":"text","text":"first"}],"source":{"kind":"user"}}}},
          {"type":"event","event":{"type":"assistant/message","seq":3,"time":1200,
            "data":{"turn":1,"message":{"role":"assistant","content":[{"type":"text","text":"one"}]}}}},
          {"type":"event","event":{"type":"user/message","seq":4,"time":1300,
            "data":{"content":[{"type":"text","text":"second"}],"source":{"kind":"user"}}}},
          {"type":"event","event":{"type":"assistant/message","seq":5,"time":1400,
            "data":{"turn":1,"message":{"role":"assistant","content":[{"type":"text","text":"two"}]}}}},
          {"type":"event","event":{"type":"turn/end","seq":6,"time":1500,
            "data":{"turn":1,"reason":{"kind":"completed"}}}}
        ]}
        """)
        let turn = try #require(result.conversationTurns().first)
        #expect(turn.prompts.count == 2)
        #expect(turn.steps.count == 2)
        #expect(turn.orderedItems.count == 4)
        let texts = turn.orderedItems.compactMap { item -> String? in
            if case .message(_, _, let text, _) = item { return text }
            return nil
        }
        #expect(texts == ["first", "one", "second", "two"])
    }

    @Test("an orphan notice is a notice, never a user bubble")
    func orphanNoticeIsNotAPrompt() throws {
        let result = try page("""
        {"sessionId":"s1","asOfSeq":5,"hasMore":false,"records":[
          {"type":"event","event":{"type":"turn/start","seq":1,"time":1000,"data":{"turn":1}}},
          {"type":"event","event":{"type":"user/message","seq":2,"time":1100,
            "data":{"content":[{"type":"text","text":"go"}],"source":{"kind":"user"}}}},
          {"type":"event","event":{"type":"assistant/message","seq":3,"time":1200,
            "data":{"turn":1,"message":{"role":"assistant","content":[{"type":"text","text":"done"}]}}}},
          {"type":"event","event":{"type":"turn/end","seq":4,"time":1300,
            "data":{"turn":1,"reason":{"kind":"completed"}}}},
          {"type":"event","event":{"type":"notice","seq":5,"time":1400,
            "data":{"text":"Background subagent obage-1 finished"}}}
        ]}
        """)
        let turns = result.conversationTurns()
        #expect(turns.count == 2)
        #expect(turns[0].prompts.count == 1)
        #expect(turns[0].steps.count == 1)
        #expect(turns[1].turn == nil)
        #expect(turns[1].prompts.isEmpty)
        #expect(turns[1].steps.count == 1)
        #expect(turns.allSatisfy { turn in
            !turn.prompts.contains { item in
                if case .notice = item { return true }
                return false
            }
        })
    }

    @Test("a notice in a page cut mid-turn lands with the answer")
    func noticeInCutPageIsAStep() throws {
        let result = try page("""
        {"sessionId":"s1","asOfSeq":3,"hasMore":false,"records":[
          {"type":"event","event":{"type":"user/message","seq":1,"time":1000,
            "data":{"content":[{"type":"text","text":"go"}],"source":{"kind":"user"}}}},
          {"type":"event","event":{"type":"notice","seq":2,"time":1100,
            "data":{"text":"Background subagent obage-1 started"}}},
          {"type":"event","event":{"type":"assistant/message","seq":3,"time":1200,
            "data":{"turn":1,"message":{"role":"assistant","content":[{"type":"text","text":"done"}]}}}}
        ]}
        """)
        let turn = try #require(result.conversationTurns().first)
        #expect(turn.prompts.count == 1)
        #expect(turn.steps.count == 2)
        #expect(turn.orderedItems.count == 3)
        if case .notice = turn.orderedItems[1] {} else { Issue.record("notice was not second") }
    }
}
