//
//  LiveActivityAttributesTests.swift
//  MizarKitTests
//
//  What actually crosses the boundary between the app and the widget.
//
//  The two are separate processes with no shared memory and no shared call
//  stack: everything the island draws was encoded by one and decoded by the
//  other. That makes the encoding a wire format between two halves of one
//  feature, which is exactly the kind of thing a test should pin -- a rename or
//  a change of date strategy here is an activity that draws nothing, or draws a
//  clock counting from 2001, on somebody's phone.
//

import Foundation
import Testing
@testable import MizarKit

/// A fixed instant, so nothing here depends on the machine's clock.
private let epoch = Date(timeIntervalSince1970: 1_800_000_000)

@Suite("The activity's attributes")
struct LiveActivityAttributesTests {
    @Test("carry the appearance the card was started in")
    func attributesCarryAppearance() throws {
        // The Lock Screen draws a Live Activity in its dark vibrant presentation
        // even in light mode, so the widget cannot read the phone's appearance
        // from its environment. The app writes it here instead, where it is
        // fixed for this card and untouched by every push that replaces the
        // content state.
        let light = DSHMizarActivityAttributes(appearance: .light)
        let data = try JSONEncoder().encode(light)
        #expect(String(decoding: data, as: UTF8.self) == #"{"appearance":"light"}"#)
        #expect(try JSONDecoder().decode(DSHMizarActivityAttributes.self, from: data) == light)

        // An activity started by the build before this field existed encodes as
        // `{}`; it must decode to the old card's dark appearance rather than
        // failing and drawing nothing.
        let legacy = Data("{}".utf8)
        #expect(try JSONDecoder().decode(DSHMizarActivityAttributes.self, from: legacy) == DSHMizarActivityAttributes(appearance: .dark))
    }

    @Test("carry the rows and their clocks as the content state")
    func stateRoundTripsAsTheContentState() throws {
        let phase = LiveActivityState(rows: [
            LiveActivityRow(
                id: "s-1",
                prompt: "把登录页那个多余的转圈去掉…",
                elapsed: 134,
                countingSince: epoch.addingTimeInterval(-134),
            ),
            LiveActivityRow(id: "s-2", prompt: "run the tests", elapsed: 60, countingSince: epoch.addingTimeInterval(-60)),
        ])
        let data = try JSONEncoder().encode(phase)

        #expect(try JSONDecoder().decode(LiveActivityState.self, from: data) == phase)
        // A finished activity is the same trip with no rows: nothing running is
        // an empty list, not a case of its own, because the payload's keys have
        // to be the state's properties.
        let finished = try JSONEncoder().encode(LiveActivityState())
        #expect(try JSONDecoder().decode(LiveActivityState.self, from: finished) == LiveActivityState())
    }

    @Test("give each row's clock as a reference-date number")
    func clocksAreReferenceDateNumbers() throws {
        // The single most load-bearing field in the payload. The widget draws
        // `Text(row.countingSince, style: .timer)` and never asks the app for
        // the time again, so a date that arrived as an ISO string, or as
        // seconds since 1970 where the reader expected seconds since 2001, is a
        // clock on the island that is wrong by 31 years or absent entirely.
        let phase = LiveActivityState(rows: [
            LiveActivityRow(id: "s-1", prompt: "run", elapsed: 134, countingSince: epoch.addingTimeInterval(-134)),
        ])

        let json = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(phase)) as? [String: Any],
        )
        // `rows` is a property of the state, so it is the outer key: the shape
        // Apple's push contract describes ("the keys are the properties of your
        // ContentState"), and therefore the shape the widget reads.
        let rows = try #require(json["rows"] as? [[String: Any]])
        let first = try #require(rows.first)
        let since = try #require(first["countingSince"] as? NSNumber)
        // 134 seconds before the instant, as a plain number: the reference-date
        // double the encoder writes by default and the decoder reads by default.
        #expect(since.doubleValue == epoch.addingTimeInterval(-134).timeIntervalSinceReferenceDate)
        #expect((first["elapsed"] as? NSNumber)?.doubleValue == 134)
    }

    @Test("can be hashed, which is what the protocol asks of a content state")
    func stateHashes() {
        // `ActivityAttributes.ContentState` is `Hashable`. Nothing in the app
        // hashes a phase today; the conformance is a requirement of the type
        // system, and this is the smallest thing that fails if it is ever lost.
        let row = LiveActivityRow(id: "s-1", prompt: "run", elapsed: 1, countingSince: epoch)
        let states: Set<LiveActivityState> = [
            LiveActivityState(rows: [row]),
            LiveActivityState(),
            LiveActivityState(rows: [row]),
        ]

        #expect(states.count == 2)
    }
}
