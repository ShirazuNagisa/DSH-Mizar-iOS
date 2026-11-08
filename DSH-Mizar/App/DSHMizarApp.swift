//
//  DSHMizarApp.swift
//  DSH-Mizar
//
//  Monitor and guide a DSH agent from a phone.
//
//  The app is a thin client on purpose. Everything that requires judgement —
//  which sessions exist, what a model costs, whether an approval is safe — is
//  decided by the host, and this app renders the answer. That is what makes it
//  possible for DSH to change underneath without shipping a new build.
//

import SwiftUI
import MizarKit

@main
struct DSHMizarApp: App {
    /// One model for the whole app: a single connection, a single pairing.
    ///
    /// `AppModel.shared` rather than a fresh instance, because a background
    /// launch can run a refresh before any view -- and therefore before anything
    /// that would have constructed a model -- has appeared. See
    /// ``BackgroundRefresh``.
    @State private var model = AppModel.shared

    /// The pieces of push that SwiftUI has no hook for: the device token, what
    /// a notification looks like while the app is open, and what a tap does.
    @UIApplicationDelegateAdaptor(PushAppDelegate.self) private var pushDelegate

    init() {
        // The Live Activity buttons are declared in the widget extension, so
        // only that binary references these two intent types. MizarKit is
        // statically linked into this app, and without an app-side reference the
        // linker dead-strips the implementations -- while App Intents metadata is
        // still generated from the module, so the system picks the app to run the
        // action and then finds no `perform()`. The symptom is
        // `LNContextErrorDomain` 2002 and a Lock Screen button that does nothing.
        //
        // A runtime read of the array, not an unused type reference: the
        // compiler may fold `_ = AllowOnceIntent.self` away, and then the
        // linker never sees the implementation. See LiveActivityIntentLink.
        _ = LiveActivityIntentLink.types.count
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .onOpenURL { url in
                    // The same payload the QR carries, arriving as a link. One
                    // parse path for both means a scanned code and a tapped
                    // link cannot behave differently.
                    guard let target = PairingURI.parse(url.absoluteString) else { return }
                    Task { await model.pair(with: target, deviceName: AppModel.deviceName) }
                }
        }
    }
}
