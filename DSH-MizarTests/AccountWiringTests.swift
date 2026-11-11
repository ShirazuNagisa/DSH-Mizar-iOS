//
//  AccountWiringTests.swift
//  DSH-MizarTests
//
//  The account API has to carry this install's id on every request. It is the
//  same value the roster knows as this device and the relay reads as
//  `x-mizar-client-id`; without it `/connect` mints every phone of the account
//  into one shared "phone" token slot, and two iOS devices revoke each other's
//  tokens in turn.
//
//  The header itself is covered in MizarKit (`AccountClientTests.clientIdHeader`).
//  What this pins is the production wiring: the app's controller must pass the
//  install id to the client it builds.
//

import XCTest

final class AccountWiringTests: XCTestCase {
    func testAccountClientIsBuiltWithTheInstallId() throws {
        try AppSourceContract.expectFragments(
            [
                "let installId = store.installId",
                "self.installId = installId",
                "AccountClient(baseURL: Self.resolvedBaseURL, clientId: installId)",
            ],
            in: "DSH-Mizar/App/AccountController.swift",
        )
    }
}
