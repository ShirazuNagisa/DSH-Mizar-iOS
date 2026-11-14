//
//  DistributionProfileTests.swift
//  DSH-MizarTests
//
//  Reading the APNs environment out of the signature.
//
//  The value decides which Apple every push for this install is sent to, and a
//  wrong answer is not a visible error: Apple refuses the token with
//  `BadDeviceToken`, and a Live Activity that cannot be addressed is a card
//  nobody can end. The reading is therefore tested on a profile shaped like the
//  real thing -- a property list inside a signed envelope -- rather than assumed
//  from the plist alone.
//

import Foundation
import Testing
@testable import DSH_Mizar

@Suite("Distribution profile")
struct DistributionProfileTests {
    /// A provisioning profile: an XML plist with bytes on both sides, which is
    /// what the CMS envelope looks like from this side of it.
    private func profile(entitlements: [String: Any]) throws -> Data {
        let root: [String: Any] = [
            "AppIDName": "DSH-Mizar",
            "Name": "iOS Team Provisioning Profile: me.shirazu.dshmizar",
            "Entitlements": entitlements,
        ]
        let plist = try PropertyListSerialization.data(
            fromPropertyList: root,
            format: .xml,
            options: 0,
        )
        var data = Data([0x30, 0x82, 0x01, 0x02, 0x06, 0x09])
        data.append(plist)
        data.append(Data([0x00, 0x01, 0x02]))
        return data
    }

    @Test("a development signature reports the sandbox entitlement")
    func readsSandboxEntitlement() throws {
        let data = try profile(entitlements: [
            "aps-environment": "development",
            "com.apple.developer.applesignin": ["Default"],
        ])
        let entitlements = Distribution.profileEntitlements(in: data)
        #expect(entitlements?["aps-environment"] as? String == "development")
    }

    @Test("a distribution signature reports the production entitlement")
    func readsProductionEntitlement() throws {
        let data = try profile(entitlements: [
            "aps-environment": "production",
            "application-identifier": "5Q2A46685M.me.shirazu.dshmizar",
        ])
        let entitlements = Distribution.profileEntitlements(in: data)
        #expect(entitlements?["aps-environment"] as? String == "production")
        // The rest of the profile is not the entitlements: a caller that reads
        // the top level would find the team's name here instead.
        let root = try PropertyListSerialization.propertyList(
            from: data[6..<(data.count - 3)],
            format: nil,
        ) as? [String: Any]
        #expect(root?["aps-environment"] == nil)
    }

    @Test("a file with no property list has nothing to say")
    func noPlistIsNil() {
        #expect(Distribution.profileEntitlements(in: Data([0x30, 0x82, 0x00])) == nil)
    }

    @Test("the app answers one of the two services, or production when unsigned")
    func answersAnEnvironment() {
        // A development build in the test runner has a profile; an unsigned one
        // has none. Both answers have to be legal, because this string is sent
        // to the host and echoed into the relay's registration.
        #expect(["sandbox", "production"].contains(Distribution.apsEnvironment ?? "production"))
    }
}
