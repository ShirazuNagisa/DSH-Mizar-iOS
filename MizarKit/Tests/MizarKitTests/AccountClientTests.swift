//
//  AccountClientTests.swift
//  MizarKitTests
//
//  What the account client sends, and what it makes of what comes back.
//
//  Both halves matter and only one is visible in the app. The request half is the
//  contract with the relay — wrong header casing, a missing bearer, a body key
//  renamed during a refactor — and it fails in production in a way no screenshot
//  shows. The response half is what the settings screen branches on: a 401 must
//  be distinguishable from a 500 so a revoked session clears the profile instead
//  of offering "try again" forever.
//

import Foundation
import Testing
@testable import MizarKit

@Suite("AccountClient")
struct AccountClientTests {
    private let baseURL = URL(string: "https://relay.example/account/v1")!
    private let device = AccountDevicePayload(
        id: "install-1",
        name: "iPhone",
        model: "iPhone18,1",
        appVersion: "0.9.2",
    )

    private static let userJSON = #"{"id":"u1","username":"shirazu","plan":"free","paidSources":[]}"#

    private func makeClient(_ transport: ScriptedHTTPTransport) -> AccountClient {
        AccountClient(baseURL: baseURL, transport: transport)
    }

    private func jsonBody(of request: URLRequest) throws -> [String: Any] {
        let data = try #require(request.httpBody)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - Requests

    @Test("registers with the documented body and path")
    func registerBody() async throws {
        let transport = ScriptedHTTPTransport()
        await transport.on(
            "register",
            body: #"{"token":"mza_new","user":\#(Self.userJSON)}"#,
        )
        let client = makeClient(transport)

        let auth = try await client.register(
            username: "shirazu",
            email: "A@B.com",
            password: "correct horse",
            code: "123456",
            device: device,
        )
        #expect(auth.token == "mza_new")
        #expect(auth.user.username == "shirazu")

        let request = try #require(await transport.recorded().first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path == "/account/v1/register")
        #expect(request.value(forHTTPHeaderField: "content-type") == "application/json")
        let body = try jsonBody(of: request)
        #expect(body["username"] as? String == "shirazu")
        #expect(body["email"] as? String == "A@B.com")
        #expect(body["password"] as? String == "correct horse")
        let sentDevice = try #require(body["device"] as? [String: Any])
        #expect(sentDevice["id"] as? String == "install-1")
        #expect(sentDevice["platform"] as? String == "ios")
        #expect(sentDevice["appVersion"] as? String == "0.9.2")
    }

    @Test("asks for the questionnaires and submits answers with the documented body")
    func surveysRoute() async throws {
        let transport = ScriptedHTTPTransport()
        await transport.on(
            "surveys",
            body: #"{"surveys":[{"id":"s1","title":"T","questions":[],"rewardDays":7,"active":true,"completed":false}]}"#,
        )
        await transport.on(
            "surveys/submit",
            body: #"{"user":\#(Self.userJSON),"rewardDays":7}"#,
        )
        let client = makeClient(transport)

        let surveys = try await client.surveys(token: "mza_token")
        #expect(surveys.count == 1)
        #expect(surveys[0].id == "s1")

        let submission = try await client.submitSurvey(
            token: "mza_token",
            surveyID: "s1",
            answers: [
                SurveyAnswer(questionId: "useful", value: .text("yes")),
                SurveyAnswer(questionId: "more", value: .choices(["a", "b"])),
            ],
        )
        #expect(submission.rewardDays == 7)
        #expect(submission.user.username == "shirazu")

        let requests = await transport.recorded()
        #expect(requests.count == 2)
        #expect(requests[0].url?.path == "/account/v1/surveys")
        #expect(requests[0].value(forHTTPHeaderField: "authorization") == "Bearer mza_token")
        #expect(requests[1].url?.path == "/account/v1/surveys/submit")
        let body = try jsonBody(of: requests[1])
        #expect(body["surveyId"] as? String == "s1")
        let answers = try #require(body["answers"] as? [[String: Any]])
        #expect(answers.count == 2)
        #expect(answers[0]["questionId"] as? String == "useful")
        #expect(answers[0]["value"] as? String == "yes")
        #expect(answers[1]["value"] as? [String] == ["a", "b"])
    }

    @Test("reads the banners through the polling twin")
    func announcementsRoute() async throws {
        let transport = ScriptedHTTPTransport()
        await transport.on(
            "announcements",
            body: #"{"announcements":[{"id":"a1","title":"Hi","body":"There","active":true}]}"#,
        )
        let client = makeClient(transport)
        let list = try await client.announcements(token: "mza_token")
        #expect(list.count == 1)
        #expect(list[0].title == "Hi")
        let request = try #require(await transport.recorded().first)
        #expect(request.url?.path == "/account/v1/announcements")
        #expect(request.value(forHTTPHeaderField: "authorization") == "Bearer mza_token")
    }

    @Test("sends the bearer token on every authenticated route")
    func bearerHeader() async throws {
        let transport = ScriptedHTTPTransport()
        await transport.on("me", body: #"{"user":\#(Self.userJSON)}"#)
        let client = makeClient(transport)

        _ = try await client.me(token: "mza_token")
        let request = try #require(await transport.recorded().first)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.path == "/account/v1/me")
        #expect(request.value(forHTTPHeaderField: "authorization") == "Bearer mza_token")
    }

    @Test("logs in with an identifier, not a username")
    func loginBody() async throws {
        let transport = ScriptedHTTPTransport()
        await transport.on(
            "login",
            body: #"{"token":"t","user":\#(Self.userJSON),"notice":{"code":"DEVICE_LIMIT","revokedDevice":"old"}}"#,
        )
        let client = makeClient(transport)
        let auth = try await client.login(identifier: "a@b.com", password: "pw", device: device)
        #expect(auth.notice?.isDeviceLimit == true)
        let body = try jsonBody(of: try #require(await transport.recorded().first))
        #expect(body["identifier"] as? String == "a@b.com")
        #expect(body["username"] == nil)
    }

    @Test("sends an Apple identity token with the raw nonce")
    func appleBody() async throws {
        let transport = ScriptedHTTPTransport()
        await transport.on("apple", body: #"{"token":"t","user":\#(Self.userJSON)}"#)
        let client = makeClient(transport)
        _ = try await client.apple(
            identityToken: "header.payload.sig",
            nonce: "raw-nonce",
            device: device,
            fullName: "Shirazu Nagisa",
        )
        let body = try jsonBody(of: try #require(await transport.recorded().first))
        #expect(body["identityToken"] as? String == "header.payload.sig")
        // The raw nonce, not its hash: the server hashes it to compare with the
        // token's claim. Sending the hash was a real way to get this wrong.
        #expect(body["nonce"] as? String == "raw-nonce")
        #expect(body["fullName"] as? String == "Shirazu Nagisa")
    }

    @Test("redeems an invite code on the documented path")
    func redeemPath() async throws {
        let transport = ScriptedHTTPTransport()
        await transport.on("invite/redeem", body: #"{"user":\#(Self.userJSON)}"#)
        let client = makeClient(transport)
        let user = try await client.redeem(token: "t", code: "ABC-123")
        #expect(user.id == "u1")
        let request = try #require(await transport.recorded().first)
        #expect(request.url?.path == "/account/v1/invite/redeem")
        #expect(request.value(forHTTPHeaderField: "authorization") == "Bearer t")
        #expect(try jsonBody(of: request)["code"] as? String == "ABC-123")
    }

    @Test("sends one transaction to /appstore/transaction")
    func appStoreTransaction() async throws {
        let transport = ScriptedHTTPTransport()
        await transport.on("appstore/transaction", body: #"{"user":\#(Self.userJSON)}"#)
        let client = makeClient(transport)
        _ = try await client.appStoreTransaction(token: "t", signedTransaction: "jws.here")
        let request = try #require(await transport.recorded().first)
        #expect(request.url?.path == "/account/v1/appstore/transaction")
        #expect(try jsonBody(of: request)["signedTransaction"] as? String == "jws.here")
    }

    @Test("syncs an array of transactions to /appstore/sync")
    func appStoreSync() async throws {
        let transport = ScriptedHTTPTransport()
        await transport.on("appstore/sync", body: #"{"user":\#(Self.userJSON)}"#)
        let client = makeClient(transport)
        _ = try await client.appStoreSync(token: "t", signedTransactions: ["a", "b"])
        let request = try #require(await transport.recorded().first)
        #expect(request.url?.path == "/account/v1/appstore/sync")
        let body = try jsonBody(of: request)
        #expect(body["signedTransactions"] as? [String] == ["a", "b"])
    }

    @Test("refuses a sync the API cannot accept, without sending it")
    func appStoreSyncLocalValidation() async throws {
        let transport = ScriptedHTTPTransport()
        let client = makeClient(transport)

        await #expect(throws: AccountError.self) {
            try await client.appStoreSync(token: "t", signedTransactions: [])
        }
        await #expect(throws: AccountError.self) {
            try await client.appStoreSync(token: "t", signedTransactions: Array(repeating: "x", count: 101))
        }
        let requests = await transport.recorded()
        #expect(requests.isEmpty)
    }

    @Test("signs out with an empty POST and deletes with the confirmation guard")
    func logoutAndDelete() async throws {
        let transport = ScriptedHTTPTransport()
        await transport.on("logout", body: #"{"ok":true}"#)
        await transport.on("delete", body: #"{"ok":true}"#)
        let client = makeClient(transport)

        try await client.logout(token: "t")
        _ = try await client.delete(token: "t")

        let requests = await transport.recorded()
        #expect(requests.count == 2)
        #expect(requests[0].url?.path == "/account/v1/logout")
        #expect(requests[0].httpBody == nil)
        #expect(requests[1].url?.path == "/account/v1/delete")
        #expect(try jsonBody(of: requests[1])["confirmation"] as? String == "DELETE")
    }

    // MARK: - Failures

    @Test("turns a 401 into a re-authentication signal with the server's code")
    func unauthenticated() async throws {
        let transport = ScriptedHTTPTransport()
        await transport.on(
            "me",
            status: 401,
            body: #"{"error":"SESSION_REVOKED","message":"This device was signed out."}"#,
        )
        let client = makeClient(transport)

        do {
            _ = try await client.me(token: "stale")
            Issue.record("expected a failure")
        } catch let error as AccountError {
            #expect(error.code == "SESSION_REVOKED")
            #expect(error.status == 401)
            #expect(error.requiresReauthentication)
            #expect(error.message == "This device was signed out.")
            #expect(!error.retryable)
        }
    }

    @Test("keeps the documented code for a refused invite")
    func inviteFailure() async throws {
        let transport = ScriptedHTTPTransport()
        await transport.on(
            "invite/redeem",
            status: 410,
            body: #"{"error":"INVITE_EXPIRED","message":"That invite code has expired."}"#,
        )
        let client = makeClient(transport)
        do {
            _ = try await client.redeem(token: "t", code: "OLD")
            Issue.record("expected a failure")
        } catch let error as AccountError {
            #expect(error.code == AccountErrorCode.inviteExpired)
            #expect(!error.retryable)
        }
    }

    @Test("marks a rate limit retryable even with no message")
    func rateLimited() async throws {
        let transport = ScriptedHTTPTransport()
        await transport.on("login", status: 429, body: "")
        let client = makeClient(transport)
        do {
            _ = try await client.login(identifier: "x", password: "y", device: device)
            Issue.record("expected a failure")
        } catch let error as AccountError {
            #expect(error.code == AccountErrorCode.rateLimited)
            #expect(error.retryable)
            #expect(!error.message.isEmpty)
        }
    }

    @Test("treats a 5xx with no body as a retryable server fault")
    func serverFault() async throws {
        let transport = ScriptedHTTPTransport()
        await transport.on("register", status: 503, body: "not json")
        let client = makeClient(transport)
        do {
            _ = try await client.register(username: "u", email: "e", password: "p", code: "123456", device: device)
            Issue.record("expected a failure")
        } catch let error as AccountError {
            #expect(error.code == AccountErrorCode.internalError)
            #expect(error.retryable)
        }
    }

    @Test("wraps a transport failure as a network account error")
    func transportFailure() async throws {
        let transport = ScriptedHTTPTransport()
        await transport.on("me", failure: URLError(.notConnectedToInternet))
        let client = makeClient(transport)
        do {
            _ = try await client.me(token: "t")
            Issue.record("expected a failure")
        } catch let error as AccountError {
            #expect(error.code == AccountErrorCode.network)
            #expect(error.retryable)
        }
    }

    @Test("reports an unreadable success body as a malformed response")
    func malformedSuccess() async throws {
        let transport = ScriptedHTTPTransport()
        await transport.on("me", body: #"{"unexpected":true}"#)
        let client = makeClient(transport)
        do {
            _ = try await client.me(token: "t")
            Issue.record("expected a failure")
        } catch let error as AccountError {
            #expect(error.code == AccountErrorCode.malformedResponse)
            #expect(!error.retryable)
        }
    }

    @Test("lists the account's computers")
    func desktops() async throws {
        let transport = ScriptedHTTPTransport()
        await transport.on(
            "desktops",
            body: #"{"desktops":[{"deviceId":"d1","name":"Mac mini","model":"Mac16,10","platform":"macos","online":true,"room":"ROOM1"}]}"#,
        )
        let client = makeClient(transport)

        let desktops = try await client.desktops(token: "sess")
        #expect(desktops.count == 1)
        #expect(desktops[0].id == "d1")
        #expect(desktops[0].online)
        #expect(desktops[0].room == "ROOM1")

        let request = try #require(await transport.recorded().first)
        #expect(request.httpMethod == "GET")
        #expect(request.url?.path.hasSuffix("/desktops") == true)
        #expect(request.value(forHTTPHeaderField: "authorization") == "Bearer sess")
    }

    @Test("asks a computer for a token and reads it back")
    func connect() async throws {
        let transport = ScriptedHTTPTransport()
        await transport.on("connect", body: #"{"room":"ROOM1","token":"mz_issued"}"#)
        let client = makeClient(transport)

        let connection = try await client.connect(token: "sess", deviceId: "d1")
        #expect(connection.room == "ROOM1")
        #expect(connection.token == "mz_issued")

        let request = try #require(await transport.recorded().first)
        #expect(request.httpMethod == "POST")
        let body = try jsonBody(of: request)
        #expect(body["deviceId"] as? String == "d1")
        #expect(request.value(forHTTPHeaderField: "authorization") == "Bearer sess")
    }

    @Test("sends this install's id so the computer can keep one token per phone")
    func clientIdHeader() async throws {
        let transport = ScriptedHTTPTransport()
        await transport.on("desktops", body: #"{"desktops":[]}"#)
        let client = AccountClient(baseURL: baseURL, transport: transport, clientId: "install-1")
        _ = try await client.desktops(token: "sess")
        let request = try #require(await transport.recorded().first)
        #expect(request.value(forHTTPHeaderField: "x-mizar-client-id") == "install-1")
    }

}