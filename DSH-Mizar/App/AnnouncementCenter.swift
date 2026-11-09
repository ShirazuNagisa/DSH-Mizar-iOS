//
//  AnnouncementCenter.swift
//  DSH-Mizar
//
//  The phone's side of the operator's banners.
//
//  The relay holds the socket; this holds the *decision*: which banner is on
//  screen, which ones this phone has already shown, and when the socket should
//  be listening at all (signed in, and the app in the foreground). Both halves
//  are deliberately small because a banner is a sentence, not a screen: the
//  worst outcome is one shown twice, and the second-worst is one missed.
//
//  Delivery is best effort by design. The relay broadcasts to whoever is
//  connected; a phone that was asleep misses it, and that is the promise the
//  server side makes. What this file does guarantee is that a banner is shown
//  once per phone: the ids it has displayed are kept in `UserDefaults`, so a
//  reconnect or a relaunch does not repeat one.
//

import Foundation
import MizarKit
import Observation
import OSLog

@MainActor
@Observable
final class AnnouncementCenter {
    /// The banner on screen, if any.
    private(set) var banner: Announcement?

    /// Ids this phone has already shown, newest last.
    private var shown: [String]
    private let defaults: UserDefaults
    /// How many ids are remembered. A banner's id is a UUID, so this is only a
    /// bound on a file that would otherwise grow for every announcement ever.
    private static let rememberedLimit = 200
    /// How long a banner stays up on its own.
    private static let visibleSeconds: Duration = .seconds(15)

    /// Where the socket lives. `nil` means the production relay; the UI tests
    /// and a preview point it at the mock host.
    private let baseURL: URL?
    private var stream: AnnouncementStream?
    private var task: Task<Void, Never>?
    private var dismissTask: Task<Void, Never>?
    private var runningToken: String?
    /// Banners that arrived while one was already up, oldest first.
    private var queued: [Announcement] = []

    /// The key the shown ids live under.
    static let shownKey = "mizar.announcements.shown"
    /// Diagnostics for the socket's lifetime: the one thing a support report
    /// about "no banner" has to answer is whether a socket was ever opened.
    private let logger = Logger(subsystem: "me.shirazu.dshmizar", category: "announcements")

    init(defaults: UserDefaults = .standard, baseURL: URL? = AnnouncementCenter.overrideURL) {
        self.defaults = defaults
        self.baseURL = baseURL
        #if DEBUG
        // A UI test that starts "fresh" is also fresh about banners: the
        // shown ids live in UserDefaults and outlive the process, so without
        // this the second run of a banner test would be told it had already
        // seen the mock.
        if ProcessInfo.processInfo.arguments.contains("-mizarAccountFreshStart") {
            defaults.removeObject(forKey: Self.shownKey)
        }
        #endif
        self.shown = defaults.stringArray(forKey: Self.shownKey) ?? []
    }

    /// `-mizarAnnouncementURL ws://127.0.0.1:19395`, for the UI tests.
    ///
    /// Debug only: a release build talks to the production socket and has no
    /// way to be pointed anywhere else, which is what keeps a stray argument
    /// from redirecting a real phone's banners.
    static var overrideURL: URL? {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-mizarAnnouncementURL"),
           index + 1 < arguments.count,
           let url = URL(string: arguments[index + 1]) {
            return url
        }
        for argument in arguments where argument.hasPrefix("-mizarAnnouncementURL=") {
            if let url = URL(string: String(argument.dropFirst("-mizarAnnouncementURL=".count))) {
                return url
            }
        }
        #endif
        return nil
    }

    // MARK: - Socket lifecycle

    /// Start or stop the socket to match the app's state.
    ///
    /// - Parameters:
    ///   - token: the account session token, or `nil` when signed out.
    ///   - active: whether the app is in the foreground.
    func update(token: String?, active: Bool) {
        logger.info("update active=\(active, privacy: .public) token=\(token != nil, privacy: .public) running=\(self.runningToken != nil, privacy: .public)")
        guard let token, !token.isEmpty, active else {
            stop()
            return
        }
        // Reconnecting for the same token would tear down a socket that is
        // already doing the one job it has.
        if runningToken == token, task != nil { return }
        stop()
        runningToken = token
        let base = baseURL ?? AnnouncementStream.productionURL
        logger.info("socket opening base=\(base.absoluteString, privacy: .public)")
        let stream = AnnouncementStream(baseURL: base)
        self.stream = stream
        task = Task { [weak self] in
            for await event in await stream.events(token: token) {
                guard let self, !Task.isCancelled else { return }
                switch event {
                case .snapshot(let announcements):
                    self.logger.info("snapshot \(announcements.count, privacy: .public)")
                    self.deliver(announcements)
                case .announcement(let announcement):
                    self.deliver([announcement])
                }
            }
        }
    }

    /// Close the socket and forget why it was open.
    func stop() {
        task?.cancel()
        task = nil
        if let stream {
            Task { await stream.stop() }
        }
        stream = nil
        runningToken = nil
    }

    // MARK: - Showing

    /// Put the next unshown live banner on screen, if there is one.
    ///
    /// - Parameter announcements: what the relay just sent.
    func deliver(_ announcements: [Announcement]) {
        var candidates = announcements
        while let next = Self.next(in: candidates, shown: Set(shown)) {
            if banner == nil {
                show(next)
            } else if !queued.contains(where: { $0.id == next.id }) {
                queued.append(next)
            }
            candidates.removeAll { $0.id == next.id }
        }
    }

    /// Dismiss the banner on screen and move to the next one, if any.
    func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        banner = nil
        guard let next = queued.first else { return }
        queued.removeFirst()
        show(next)
    }

    /// Mark one as acted on: the button took the operator somewhere, so the
    /// banner has done its job and comes down.
    func acted() {
        dismiss()
    }

    /// Whether this phone has already shown one.
    ///
    /// - Parameter id: the announcement's id.
    /// - Returns: whether it was displayed before.
    func isShown(_ id: String) -> Bool {
        shown.contains(id)
    }

    /// Put one on screen, remember it, and set its timer.
    private func show(_ announcement: Announcement) {
        banner = announcement
        remember(announcement.id)
        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: Self.visibleSeconds)
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    /// Record an id, trimming the oldest when the bound is reached.
    private func remember(_ id: String) {
        guard !shown.contains(id) else { return }
        shown.append(id)
        if shown.count > Self.rememberedLimit {
            shown.removeFirst(shown.count - Self.rememberedLimit)
        }
        defaults.set(shown, forKey: Self.shownKey)
    }

    // MARK: - Decisions worth a test

    /// The banner a fresh snapshot should show, if any.
    ///
    /// Pure so the rule is testable without a socket: the newest live banner
    /// this phone has not shown yet.
    ///
    /// - Parameters:
    ///   - announcements: the snapshot.
    ///   - shown: ids already displayed.
    ///   - now: the clock, for expiry.
    /// - Returns: the banner to show, or `nil`.
    static func next(
        in announcements: [Announcement],
        shown: Set<String>,
        now: Date = Date(),
    ) -> Announcement? {
        announcements
            .filter { announcement in
                guard !shown.contains(announcement.id), announcement.active != false else { return false }
                guard let expiresAt = announcement.expiresAt else { return true }
                return expiresAt > now
            }
            .max { left, right in
                (left.createdAt ?? .distantPast) < (right.createdAt ?? .distantPast)
            }
    }
}
