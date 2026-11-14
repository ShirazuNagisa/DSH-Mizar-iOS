//
//  Distribution.swift
//  DSH-Mizar
//
//  Which channel this build came from.
//
//  The subscription is not sellable from a TestFlight build: the products are
//  not live for testers and the sandbox sheet is a confusing thing to show
//  somebody who was invited to try the app. The test is Apple's own: a TestFlight
//  (and simulator/development) install carries `sandboxReceipt`, an App Store
//  install carries `receipt`.
//
//  The second question asked here is not the same one, even though it is about
//  the same install: which of Apple's two push services issued this build's
//  tokens. A receipt cannot answer it -- a development build that used StoreKit
//  has a `sandboxReceipt` too -- so the answer comes from the profile that
//  signed the build.
//

import Foundation

enum Distribution {
    /// Whether this build runs from TestFlight (or a sandbox receipt).
    ///
    /// `-mizarMockTestFlight` is the debug seam: no simulator install has a
    /// receipt, so a UI test cannot reach this state any other way.
    static var isTestFlight: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-mizarMockTestFlight") { return true }
        #endif
        return Bundle.main.appStoreReceiptURL?.lastPathComponent == "sandboxReceipt"
    }

    /// Which APNs this install's tokens belong to: `sandbox`, `production`, or
    /// `nil` when the bundle has no profile to ask (an App Store or TestFlight
    /// install, both of which use production).
    ///
    /// A device token does not say which Apple minted it, and Apple refuses a
    /// token presented to the other one with `BadDeviceToken` -- an answer that
    /// names neither the environment nor the fix. The app therefore has to say,
    /// and the right source is the signature, not the compiler: `#if DEBUG` was
    /// the old one, and a Release build installed from Xcode is optimised
    /// (`DEBUG` off) but signed for development, so it reported production for a
    /// sandbox token. Every push for that install was then refused, including
    /// the Live Activity end, and a finished session kept counting on the Lock
    /// Screen with nothing able to take the card down.
    ///
    /// A development or Ad Hoc install carries `embedded.mobileprovision`, whose
    /// `Entitlements.aps-environment` is exactly the value Apple checks the token
    /// against. App Store and TestFlight installs carry no profile, and both are
    /// production.
    static var apsEnvironment: String? {
        guard
            let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
            let data = try? Data(contentsOf: url),
            let entitlements = profileEntitlements(in: data),
            let environment = entitlements["aps-environment"] as? String
        else { return nil }
        return environment == "development" ? "sandbox" : "production"
    }

    /// The entitlements of a signed provisioning profile.
    ///
    /// The file is a CMS envelope around a property list. The signature wraps
    /// the payload rather than sealing it, so the payload is found by its own
    /// delimiters instead of by opening the envelope, which would need the Apple
    /// root certificate and a policy decision this app has no use for.
    ///
    /// Internal rather than private so a test can hand it a synthetic profile:
    /// the real one only exists in a signed build, which is exactly the build a
    /// unit test is not.
    ///
    /// - Parameter data - the profile, `embedded.mobileprovision`.
    /// - Returns: the `Entitlements` dictionary, or `nil` when there is no plist
    ///   to read.
    static func profileEntitlements(in data: Data) -> [String: Any]? {
        guard
            let start = data.range(of: Data("<?xml".utf8)),
            let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex)
        else { return nil }
        let plist = data[start.lowerBound..<end.upperBound]
        guard
            let root = try? PropertyListSerialization.propertyList(from: plist, format: nil),
            let dictionary = root as? [String: Any]
        else { return nil }
        return dictionary["Entitlements"] as? [String: Any]
    }
}
