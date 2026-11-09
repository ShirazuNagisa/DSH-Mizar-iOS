//
//  AnnouncementSurveyTests.swift
//  MizarKitTests
//
//  The wire shapes the relay's 0.9.9 features use: the banner socket's two
//  frames, the banner model's rules, and the questionnaire form's values.
//
//  These are the facts a server change would break silently -- a renamed key
//  decodes as a missing field, an unknown target turns a button into a
//  decoration -- so they are pinned here rather than discovered on a phone.
//

import Foundation
import Testing
@testable import MizarKit

@Suite("Announcements and questionnaires")
struct AnnouncementSurveyTests {
    // MARK: - Announcements

    @Test("decodes the snapshot frame and the live frame")
    func decodesFrames() throws {
        let snapshot = Data(
            #"""
            {"type":"snapshot","announcements":[
              {"id":"a1","title":"Hello","body":"One.","symbol":"megaphone","tone":"info",
               "button":{"label":"Open","target":"notifications"},
               "createdAt":1794000000000,"expiresAt":null,"active":true}
            ]}
            """#.utf8,
        )
        let events = AnnouncementStream.decode(snapshot)
        #expect(events.count == 1)
        guard case .snapshot(let list) = events[0] else {
            Issue.record("the snapshot frame did not decode as a snapshot")
            return
        }
        #expect(list.count == 1)
        #expect(list[0].title == "Hello")
        #expect(list[0].actionableButton?.destination == .notifications)
        #expect(list[0].isLive)

        let live = Data(
            #"""
            {"type":"announcement","announcement":{
              "id":"a2","title":"Later","body":"Two.","symbol":null,"tone":null,
              "button":null,"createdAt":1794000001000,"expiresAt":null,"active":true}}
            """#.utf8,
        )
        guard case .announcement(let one) = AnnouncementStream.decode(live)[0] else {
            Issue.record("the live frame did not decode as an announcement")
            return
        }
        #expect(one.id == "a2")
        #expect(one.resolvedSymbol == "megaphone")
        #expect(one.actionableButton == nil)
    }

    @Test("ignores frames it does not understand")
    func ignoresUnknownFrames() {
        #expect(AnnouncementStream.decode(Data(#"{"type":"other"}"#.utf8)).isEmpty)
        #expect(AnnouncementStream.decode(Data("not json".utf8)).isEmpty)
    }

    @Test("a banner with an unknown destination keeps its sentence and loses its button")
    func unknownTargetHidesButton() {
        let banner = Announcement(
            title: "T",
            body: "B",
            button: AnnouncementButton(label: "Go", target: "a-shelf-this-build-does-not-know"),
        )
        #expect(banner.actionableButton == nil)
        #expect(banner.isLive)
    }

    @Test("an expired banner is not live")
    func expiryIsLive() {
        let past = Announcement(title: "T", body: "B", expiresAt: Date(timeIntervalSince1970: 1_000))
        #expect(!past.isLive)
        let future = Announcement(title: "T", body: "B", expiresAt: Date().addingTimeInterval(60))
        #expect(future.isLive)
    }

    @Test("the targets are the relay's vocabulary")
    func targetVocabulary() {
        #expect(
            AnnouncementTarget.allRawValues == [
                "account", "notifications", "sending", "transfer",
                "localAgent", "files", "community", "logs", "about",
            ],
        )
    }

    // MARK: - Questionnaires

    @Test("decodes a survey, its questions and this account's state")
    func decodesSurvey() throws {
        let json = Data(
            #"""
            {"id":"s1","title":"How was it?","summary":"Two questions.","rewardDays":7,
             "active":true,"expiresAt":null,"completed":false,"completedAt":null,
             "questions":[
               {"id":"useful","type":"single","prompt":"Useful?","required":true,
                "options":[{"id":"yes","label":"Yes"},{"id":"no","label":"No"}]},
               {"id":"more","type":"multi","prompt":"What helped?","required":false,
                "options":[{"id":"a","label":"A"},{"id":"b","label":"B"}]},
               {"id":"note","type":"text","prompt":"Anything else?","required":false,"maxLength":200}
             ]}
            """#.utf8,
        )
        let survey = try AccountCoding.decoder().decode(Survey.self, from: json)
        #expect(survey.id == "s1")
        #expect(survey.rewardDays == 7)
        #expect(survey.questions.count == 3)
        #expect(survey.questions[0].type == .single)
        #expect(survey.questions[0].options.map(\.id) == ["yes", "no"])
        #expect(survey.questions[1].type == .multi)
        #expect(survey.questions[2].type == .text)
        #expect(survey.questions[2].maxLength == 200)
        #expect(survey.isOpen)
    }

    @Test("an answer is a string or a list, and survives a round trip")
    func answerValueRoundTrip() throws {
        let text = try AccountCoding.encoder().encode(SurveyAnswerValue.text("hello"))
        #expect(String(data: text, encoding: .utf8) == #""hello""#)
        let decodedText = try AccountCoding.decoder().decode(SurveyAnswerValue.self, from: text)
        #expect(decodedText == .text("hello"))

        let choices = try AccountCoding.encoder().encode(SurveyAnswerValue.choices(["a", "b"]))
        let decodedChoices = try AccountCoding.decoder().decode(SurveyAnswerValue.self, from: choices)
        #expect(decodedChoices == .choices(["a", "b"]))
    }

    @Test("a completed survey is not open")
    func completedIsNotOpen() throws {
        let json = Data(
            #"{"id":"s1","title":"T","questions":[],"completed":true,"active":true,"rewardDays":7}"#.utf8,
        )
        let survey = try AccountCoding.decoder().decode(Survey.self, from: json)
        #expect(!survey.isOpen)
    }
}
