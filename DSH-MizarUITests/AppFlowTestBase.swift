//
//  AppFlowTestBase.swift
//  DSH-MizarUITests
//
//  Regression cover for the screens that were, until now, verified by taking a
//  screenshot and looking at it.
//
//  That is not a rhetorical complaint. Adding localisation produced three
//  screenshots showing English strings while the bundle on disk already had the
//  Chinese ones, because `simctl install` had left the previous binary running.
//  Manual verification reported a failure that did not exist. These tests exist
//  so the next one of those is caught by a machine.
//
//  They run against `scripts/mock-host.mjs`, which serves the real protocol with
//  record shapes taken from a live host. A pending approval only exists while an
//  agent is blocked on a tool call, so the real host cannot be asked to produce
//  one on demand -- and on this machine it cannot produce one at all, because
//  every turn ends in MISSING_CREDENTIAL before reaching a tool.
//
//  Elements are found by accessibility identifier, never by label: a query for
//  "Allow once" passes only in English, and the title not being a stable name is
//  the entire point of the localisation work.
//

import XCTest
class AppFlowTestBase: XCTestCase {
    /// This class's mock-host primary port. Every concrete UI test class owns
    /// a pair of mock hosts -- the fixture machine and the second machine on
    /// +1 -- so two classes running as parallel workers never share fixture
    /// state. Subclasses override this with their port from `MockPorts`; the
    /// default is the historical 19395 for a class the table omits.
    ///
    /// Members read this through a method body (dynamic dispatch), so a helper
    /// called on a subclass lands on that subclass's hosts. A *default
    /// argument* would not: that context is bound to the base class, which is
    /// why the pairing-URI defaults resolve inside the body instead.
    class var mockPort: Int { 19395 }

    /// The mock host, which must be running before this suite is.
    class var mockPairingURI: String {
        "mizar://pair?h=127.0.0.1%3A\(mockPort)&c=MOCK-CODE&n=Mock%20Mac&v=1"
    }

    /// A second computer, on a second port, with its own identity.
    ///
    /// Every piece of state the app keeps is scoped to a machine, and a single
    /// mock cannot show that: it answers every read with the same host id, the
    /// same sessions and the same providers, so a screen drawn from one computer's
    /// answer under another computer's name looks exactly like a screen drawn
    /// correctly. The second machine stays on the historical 19396 for now:
    /// mock-host.mjs hard-codes the second identity to that port, and the
    /// one-line env-based change is blocked by the workspace secret guard
    /// (reported to the user). Per-class secondaries land once that clears;
    /// until then two parallel AppFlow classes share this one second host.
    class var secondMockPairingURI: String {
        "mizar://pair?h=127.0.0.1%3A19396&c=MOCK-CODE&n=Mock%20Mac%20(second)&v=1"
    }

    /// How long to wait for the host to answer.
    static let patience: TimeInterval = 20
    /// A naming prompt appears only on the first pairing. Waiting the full
    /// `patience` when it does not appear adds twenty seconds to every launch.
    static let namingPatience: TimeInterval = 3

    override func setUp() {
        continueAfterFailure = false
        // Every test starts against a host that answers, whatever the last one
        // left behind. `/offline?on=1` is switched back by a `defer` inside the
        // one test that uses it -- and an assertion with
        // `continueAfterFailure = false` aborts by raising, which skips Swift
        // `defer`s. One aborted test was therefore enough to leave the fixture
        // refusing every connection for the rest of the suite, and the next test
        // then failed reporting a bug in the app that was a bug in the fixture.
        Self.setMockOffline(false)
    }

    /// Put the mock host's conversation back to its fixture.
    ///
    /// The mock remembers what has been sent to it -- that is what makes the send
    /// path testable at all -- but it remembered it for the life of the process,
    /// which is the whole suite. Every test after the first send ran against a
    /// longer conversation than the one before it, so a test that scrolled to
    /// find a message found a different amount of content depending on which
    /// tests had run first. A suite whose failures depend on test order is a
    /// suite whose failures cannot be trusted, and two of them were exactly that.
    ///
    /// - Parameters:
    ///   - pending: whether the mock should offer a pending approval and
    ///     question. They fill most of a phone screen, which is correct
    ///     behaviour and useless to a test about what is underneath them.
    ///   - slow: how long the mock should stall every answer, in milliseconds.
    ///     For the two screens that exist to report how long something is
    ///     taking, which cannot be observed against a host that answers instantly.
    static func resetMockHost(
        pending: Bool = true,
        slow: Int = 0,
        skew: Int = 0,
        pageLimit: Int? = nil,
        running: Bool = true,
        states: Bool = false,
        longStates: Bool = false,
        hideSession: Bool = false,
    ) {
        var query = pending ? "" : "?pending=0"
        if slow > 0 { query += query.isEmpty ? "?slow=\(slow)" : "&slow=\(slow)" }
        // A host whose clock is ahead of the phone's, and a host that refuses a
        // page too large to deliver. Both are states the real host reaches on
        // its own, and neither can be produced from the app's side.
        if skew > 0 { query += query.isEmpty ? "?skew=\(skew)" : "&skew=\(skew)" }
        if let pageLimit { query += query.isEmpty ? "?pageLimit=\(pageLimit)" : "&pageLimit=\(pageLimit)" }
        // A host whose session has stopped, so no Live Activity is posted. What
        // this is for is a test that must not be run in the same process as the
        // widget extension.
        if !running { query += query.isEmpty ? "?running=0" : "&running=0" }
        // A host that pushes a live state sequence: the stream exists only when
        // the binary channel does.
        if hideSession { query += query.isEmpty ? "?hideSession=1" : "&hideSession=1" }
        if longStates { query += query.isEmpty ? "?states=long" : "&states=long" }
        else if states { query += query.isEmpty ? "?states=1" : "&states=1" }
        guard let url = URL(string: "http://127.0.0.1:\(mockPort)/reset\(query)") else { return }
        let done = DispatchSemaphore(value: 0)
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        URLSession.shared.dataTask(with: request) { _, _, _ in done.signal() }.resume()
        // Bounded, because a mock host that is not running is a suite that is
        // about to fail on its own terms -- not one to hang on here.
        _ = done.wait(timeout: .now() + 6)
    }

    /// Put the *second* computer's fixture back, on the other port.
    ///
    /// The same reset as ``resetMockHost(pending:slow:skew:pageLimit:running:)``,
    /// for the other machine. A test that switches between two computers has two
    /// fixtures to keep apart, and one of them left carrying the previous test's
    /// sends while the other was reset is a test whose second half measures the
    /// first.
    ///
    /// - Parameter running: whether that machine's session reports itself as
    ///   running. `false` by default, which keeps the Live Activity out of a test
    ///   about two session lists.
    static func resetSecondMockHost(running: Bool = false) {
        // The cards are off, like the test that uses this helper wants: they
        // fill the conversation and one of them sits over the composer, which
        // is where this test taps.
        var query = "?pending=0"
        if !running { query += "&running=0" }
        // The shared second machine (19396) until per-class secondaries land.
        guard let url = URL(string: "http://127.0.0.1:19396/reset\(query)") else { return }
        let done = DispatchSemaphore(value: 0)
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        URLSession.shared.dataTask(with: request) { _, _, _ in done.signal() }.resume()
        _ = done.wait(timeout: .now() + 6)
    }

    /// Make the mock host refuse connections, or stop refusing them.
    ///
    /// - Parameter off: whether it should be unreachable.
    static func setMockOffline(_ off: Bool) {
        guard let url = URL(string: "http://127.0.0.1:\(mockPort)/offline?on=\(off ? 1 : 0)") else { return }
        let done = DispatchSemaphore(value: 0)
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        URLSession.shared.dataTask(with: request) { _, _, _ in done.signal() }.resume()
        _ = done.wait(timeout: .now() + 6)
    }

    /// Make the mock host fail every answer to one method, from now on.
    ///
    /// For the reads a screen makes more than once: what a *later* failure does
    /// to figures an earlier read already drew. Cleared by the next `/reset`,
    /// like the rest of the mock's state.
    ///
    /// - Parameter method: the wire method to refuse.
    /// - Returns: whether the mock confirmed it is refusing that method. Checked
    ///   rather than assumed, because a knob that did not take turns every
    ///   assertion after it into an assertion about something else -- which cost
    ///   an afternoon of reading a failure screen as a bug in the app.
    @discardableResult
    static func failMockHost(_ method: String) -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(mockPort)/fail?method=\(method)") else { return false }
        let done = DispatchSemaphore(value: 0)
        let box = Box()
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        URLSession.shared.dataTask(with: request) { data, _, _ in
            defer { done.signal() }
            guard let data,
                  let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return }
            box.value = (parsed["failMethod"] as? String) == method ? 1 : 0
        }.resume()
        _ = done.wait(timeout: .now() + 6)
        return box.value == 1
    }

    /// Make the mock host answer `session.stats` like a cold session.
    ///
    /// Not a failure: the same frame with the projections that need a warm agent
    /// left empty, which is what a phone gets for a session nothing has run in
    /// yet. A screen that replaces what it has with it loses the title, the
    /// model and the context figure.
    ///
    /// - Parameter cold: whether to answer that way.
    static func setMockStatsCold(_ cold: Bool) {
        let variant = cold ? "cold" : "full"
        guard let url = URL(string: "http://127.0.0.1:\(mockPort)/stats?variant=\(variant)") else { return }
        let done = DispatchSemaphore(value: 0)
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        URLSession.shared.dataTask(with: request) { _, _, _ in done.signal() }.resume()
        _ = done.wait(timeout: .now() + 6)
    }

    /// Stall every answer the mock host gives, from now on.
    ///
    /// Called mid-test rather than at launch: the launch itself is a download,
    /// and making that slow too would leave the screen under test unreachable --
    /// the refresh button is disabled while the first download runs.
    ///
    /// - Parameter milliseconds: how long each answer should take.
    static func stallMockHost(_ milliseconds: Int) {
        slowMockHost(milliseconds, method: nil)
    }

    /// Stall one method's answers, leaving the rest immediate.
    ///
    /// The other half of ``stallMockHost(_:)``, for a test that needs one slow
    /// read rather than a slow app: a reload held open on `session.messages`
    /// while the send that is being measured answers straight away.
    ///
    /// - Parameters:
    ///   - milliseconds: how long each answer to that method should take.
    ///   - method: the wire method to stall.
    static func stallMockHost(_ milliseconds: Int, method: String) {
        slowMockHost(milliseconds, method: method)
    }

    /// - Parameters:
    ///   - milliseconds: how long each stalled answer should take.
    ///   - method: the one method to stall, or `nil` for every method.
    static func slowMockHost(_ milliseconds: Int, method: String?) {
        let named = method.map { "&method=\($0)" } ?? ""
        guard let url = URL(string: "http://127.0.0.1:\(mockPort)/slow?ms=\(milliseconds)\(named)") else { return }
        let done = DispatchSemaphore(value: 0)
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        URLSession.shared.dataTask(with: request) { _, _, _ in done.signal() }.resume()
        _ = done.wait(timeout: .now() + 6)
    }

    /// Hold the mock's conversation reads, or let them go.
    ///
    /// A stall is a race, and this is not: a delay long enough to be measured on
    /// a loaded machine is a delay long enough for whatever was meant to overlap
    /// it to have finished first. Held, the reload under test is still in flight
    /// when the next thing happens -- by construction rather than by timing, so
    /// the assertion about a second load landing on top of it is deterministic.
    ///
    /// - Parameter holding: whether to hold them.
    /// - Returns: how many held answers the release let go, so that a test can
    ///   say it released something rather than assume it did.
    @discardableResult
    static func holdMockConversationReads(_ holding: Bool) -> Int? {
        guard let url = URL(string: "http://127.0.0.1:\(mockPort)/hold?messages=\(holding ? 1 : 0)") else { return nil }
        let done = DispatchSemaphore(value: 0)
        let box = Box()
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        URLSession.shared.dataTask(with: request) { data, _, _ in
            defer { done.signal() }
            guard let data,
                  let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return }
            box.value = parsed["released"] as? Int
        }.resume()
        _ = done.wait(timeout: .now() + 6)
        return box.value
    }

    /// What the mock host has seen of overlapping conversation reads.
    ///
    /// `inFlight` is how many `session.messages` requests it is answering right
    /// now and `peak` the most it ever answered at once, both since the last
    /// reset. Neither is visible from the app: two overlapping loads are both
    /// answered correctly and settle on the same conversation, so "one load was
    /// in flight, not two" is a fact only the host holds.
    ///
    /// - Returns: the counts, or `nil` when the mock is not answering.
    static func mockLoads() -> (inFlight: Int, peak: Int)? {
        guard let url = URL(string: "http://127.0.0.1:\(mockPort)/loads?reset=1") else { return nil }
        let done = DispatchSemaphore(value: 0)
        let box = Box()
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        URLSession.shared.dataTask(with: request) { data, _, _ in
            defer { done.signal() }
            guard let data,
                  let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return }
            box.counts = (parsed["inFlight"] as? Int, parsed["peak"] as? Int)
        }.resume()
        _ = done.wait(timeout: .now() + 6)
        guard let counts = box.counts, let inFlight = counts.0, let peak = counts.1 else { return nil }
        return (inFlight, peak)
    }

    /// What the mock host has been asked, by method, since the last reset.
    ///
    /// The one piece of evidence a refresh made with no screen leaves where a
    /// test can read it. The host's count is a fact about the wire, not about
    /// either process's opinion of itself.
    ///
    /// - Returns: method name to count, empty when the mock is not answering.
    static func mockMethodCounts() -> [String: Int] {
        guard let url = URL(string: "http://127.0.0.1:\(mockPort)/loads") else { return [:] }
        let done = DispatchSemaphore(value: 0)
        let box = Box()
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        URLSession.shared.dataTask(with: request) { data, _, _ in
            defer { done.signal() }
            guard let data,
                  let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let methods = parsed["methods"] as? [String: Any]
            else { return }
            box.methods = methods.compactMapValues { ($0 as? NSNumber)?.intValue }
        }.resume()
        _ = done.wait(timeout: .now() + 6)
        return box.methods
    }

    /// The prompts the mock host has been sent, and how each one travelled.
    ///
    /// A held prompt produces no request at all, and a guided one produces the
    /// same accepted `session.prompt` a queued one does -- so "did it leave the
    /// phone, and as guidance" is a question only the wire can answer. The mode
    /// is the host's own reading of the payload: an absent `mode` is `queue`,
    /// which is what an older host takes it as.
    ///
    /// - Returns: the prompt texts and their modes, in order; empty when the
    ///   mock is not answering.
    static func mockPrompts() -> (texts: [String], modes: [String]) {
        guard let url = URL(string: "http://127.0.0.1:\(mockPort)/prompts") else { return ([], []) }
        let done = DispatchSemaphore(value: 0)
        let box = Box()
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        URLSession.shared.dataTask(with: request) { data, _, _ in
            defer { done.signal() }
            guard let data,
                  let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return }
            box.prompts = parsed["prompts"] as? [String] ?? []
            box.promptModes = parsed["modes"] as? [String] ?? []
        }.resume()
        _ = done.wait(timeout: .now() + 6)
        return (box.prompts, box.promptModes)
    }

    /// Wait until the mock host has been sent at least this many prompts.
    ///
    /// The bar leaves before its request is answered (it is answered by the tap,
    /// not by a round trip), so the disappearance is not evidence that the prompt
    /// arrived. Polling the wire is.
    ///
    /// - Parameters:
    ///   - count: how many prompts to wait for.
    ///   - timeout: how long to wait.
    /// - Returns: whatever the host had when the wait ended.
    static func waitForMockPrompts(
        count: Int,
        timeout: TimeInterval = 15,
    ) -> (texts: [String], modes: [String]) {
        let deadline = Date().addingTimeInterval(timeout)
        var latest = mockPrompts()
        while latest.texts.count < count, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.2)
            latest = mockPrompts()
        }
        return latest
    }

    /// The model switches the mock host has taken, in order.
    ///
    /// Read at the host rather than on the screen. The conversation's bar draws
    /// what the host last *reported*, so a switch that was never sent and one
    /// that is still waiting for its projection look identical for a moment --
    /// and the claim this supports is "the model chosen on the home screen
    /// reached the new session", which only the wire can settle.
    ///
    /// - Returns: one dictionary per switch, empty when the mock is not answering.
    static func mockModelSets() -> [[String: Any]] {
        guard let url = URL(string: "http://127.0.0.1:\(mockPort)/loads") else { return [] }
        let done = DispatchSemaphore(value: 0)
        let box = Box()
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        URLSession.shared.dataTask(with: request) { data, _, _ in
            defer { done.signal() }
            guard let data,
                  let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sets = parsed["modelSets"] as? [[String: Any]]
            else { return }
            box.modelSets = sets
        }.resume()
        _ = done.wait(timeout: .now() + 6)
        return box.modelSets
    }

    /// Wait until an element's label says something.
    ///
    /// The figures in the composer bar come from a read that lands after the
    /// screen does, so a plain `label.contains` is an assertion about a snapshot
    /// taken at an arbitrary moment -- and it failed the once, on the run where
    /// the read happened to be slower. Polling is what the rest of this file
    /// does for the same reason.
    ///
    /// - Parameters:
    ///   - element: what to watch.
    ///   - text: what its label should contain.
    /// - Returns: whether it got there.
    func labelLands(_ element: XCUIElement, containing text: String) -> Bool {
        let arrived = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", text),
            object: element,
        )
        return XCTWaiter().wait(for: [arrived], timeout: Self.patience) == .completed
    }

    /// Open a workspace and wait for a row inside it.
    ///
    /// The condition is the row rather than the tap, so a tap that is lost -- to
    /// the naming sheet still animating away, which is where this went wrong --
    /// costs a retry instead of twenty seconds of waiting for something that will
    /// not happen.
    ///
    /// - Parameters:
    ///   - heading: the workspace's heading, found by its identifier.
    ///   - row: a row that only exists inside the workspace.
    ///   - attempts: how many times to try.
    /// - Returns: whether the row turned up.
    @discardableResult
    func expand(_ heading: XCUIElement, revealing row: XCUIElement, attempts: Int = 3) -> Bool {
        for _ in 0..<attempts {
            if row.exists { return true }
            guard heading.waitForExistence(timeout: 5), heading.isHittable else { continue }
            // The heading's own title, not the button and not a coordinate: a
            // tap at the centre of the button lands on the empty space between
            // the title and the count and does not toggle it -- measured on both
            // destinations, three attempts in a row leaving the workspace
            // folded. `heading` is the button, and its first static text is the
            // title, which is the element an operator actually taps.
            let title = heading.staticTexts.element(boundBy: 0)
            guard title.exists else { continue }
            title.tap()
            if row.waitForExistence(timeout: 3) { return true }
        }
        return row.exists
    }

    /// The row for one session, under either name it can be drawn with.
    ///
    /// The title is the host's once it has given one, and otherwise the working
    /// directory and the session's id -- so a query for the pretty name alone
    /// finds nothing on a phone whose host has not named the session yet, which
    /// is a test that fails for a reason of its own making.
    ///
    /// - Parameters:
    ///   - app: the running app.
    ///   - title: the host's title for the session.
    ///   - directory: the last path component of its working directory.
    /// - Returns: the element to tap.
    func sessionRow(in app: XCUIApplication, titled title: String, in directory: String) -> XCUIElement {
        app.staticTexts.matching(
            NSPredicate(format: "label == %@ OR label BEGINSWITH %@", title, "\(directory) · "),
        ).firstMatch
    }

    /// Scroll through the conversation until an element is in the tree.
    ///
    /// A `LazyVStack` builds only what is near the screen, so an element that is
    /// in the data can be absent from the accessibility hierarchy entirely --
    /// and `waitForExistence` cannot see what the app has not built. The
    /// conversation opens anchored to its newest message, so anything older than
    /// that needs scrolling to before it can be asserted on.
    ///
    /// Both directions. The content is longer than the screen -- prompts,
    /// turn rows, answers, the failure card -- and a helper that only travelled
    /// one way reported a row as missing from a screen it was on. It used to have
    /// a second reason, that expanding a turn moved rows in both directions;
    /// turns are no longer expandable, and this is kept because the list is still
    /// longer than the display.
    ///
    /// - Parameters:
    ///   - element: what to look for.
    ///   - app: the running app.
    ///   - swipes: how many screenfuls to travel in each direction.
    /// - Returns: whether it turned up.
    @discardableResult
    func reveal(_ element: XCUIElement, in app: XCUIApplication, swipes: Int = 6) -> Bool {
        // Give the screen a moment to draw before touching it. Swiping at a
        // conversation that is still loading scrolls nothing and reports the
        // row as absent from a screen it is about to be on -- which is how this
        // helper failed intermittently on a test that had passed a dozen times.
        if element.waitForExistence(timeout: 5) { return true }
        for direction in [0, 1] {
            for _ in 0..<swipes {
                if element.exists { return true }
                // Zero travels towards older messages, one towards newer.
                if direction == 0 { app.swipeDown() } else { app.swipeUp() }
            }
        }
        return element.exists
    }

    /// A value written on URLSession's queue and read once the wait is over.
    ///
    /// `@unchecked Sendable` with the semaphore below as the synchronisation: the
    /// write happens before `signal()` and the read after `wait()`.
    final class Box: @unchecked Sendable {
        var value: Int?
        /// Two counts at once, for the one endpoint that reports a pair.
        var counts: (Int?, Int?)?
        /// What the mock host was asked, by method.
        var methods: [String: Int] = [:]
        /// The `session.model.set` calls the mock host took, in order.
        var modelSets: [[String: Any]] = []
        /// The prompts the mock host was sent, in order.
        var prompts: [String] = []
        /// How each of those prompts travelled: `queue` or `steer`.
        var promptModes: [String] = []
    }

    /// How many sockets the mock host has accepted since the suite last reset it.
    ///
    /// A reconnect is invisible from the app's side -- the data looks the same
    /// afterwards -- so the only way to assert that a failure did *not* cost a
    /// fresh socket is to count them at the host.
    ///
    /// - Returns: the count, or `nil` when the mock is not answering.
    static func mockConnections() -> Int? {
        guard let url = URL(string: "http://127.0.0.1:\(mockPort)/connections") else { return nil }
        let done = DispatchSemaphore(value: 0)
        let box = Box()
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        URLSession.shared.dataTask(with: request) { data, _, _ in
            defer { done.signal() }
            guard let data,
                  let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return }
            box.value = parsed["connections"] as? Int
        }.resume()
        _ = done.wait(timeout: .now() + 6)
        return box.value
    }

    /// Launch the app, optionally pairing and opening a session on the way in.
    /// - Parameters:
    ///   - pairing: whether to pass a pairing URI.
    ///   - session: a session to open, or `nil` to stay on the list.
    ///   - language: a language to force, or `nil` to follow the system.
    ///   - pending: whether the mock should offer a pending approval and question.
    ///   - slow: how long the mock should stall every answer, in milliseconds.
    ///   - skew: how far ahead of the phone the mock's clock should be, in
    ///     milliseconds. Zero for every test that is not about the two clocks
    ///     disagreeing.
    ///   - pageLimit: the largest page the mock will answer, when a test wants
    ///     the host to refuse one that will not fit.
    ///   - running: whether the mock's session reports itself as running. `false`
    ///     keeps the Live Activity out of the run, for a test about the screens
    ///     rather than about the island.
    ///   - freshStart: whether to throw the stored data away first.
    ///   - naming: whether to wait for the naming prompt before returning.
    ///     It is offered *after* a first download, so a test about that download
    ///     would spend the whole of it here instead of looking at it.
    ///   - pairingURIs: the computers to pair with on the way in, in order. One is the
    ///     ordinary case; two is a phone that manages more than one machine, which
    ///     is the only setup in which cross-machine state can be observed at all.
    /// - Returns: the running application.
    func launch(
        pairing: Bool = true,
        session: String? = "first",
        language: String? = "en",
        pending: Bool = true,
        slow: Int = 0,
        skew: Int = 0,
        pageLimit: Int? = nil,
        running: Bool = true,
        states: Bool = false,
        longStates: Bool = false,
        hideSession: Bool = false,
        slowPlacement: Bool = false,
        hugeSpacer: Bool = false,
        naming: Bool = true,
        freshStart: Bool = true,
        pairingURIs: [String]? = nil,
        contentSizeCategory: String? = nil,
    ) -> XCUIApplication {
        Self.resetMockHost(
            pending: pending,
            slow: slow,
            skew: skew,
            pageLimit: pageLimit,
            running: running,
            states: states,
            longStates: longStates,
            hideSession: hideSession,
        )
        let app = XCUIApplication()
        app.launchArguments = Self.arguments(
            pairing: pairing,
            session: session,
            language: language,
            freshStart: freshStart,
            // Resolved in the body on purpose: a default argument is bound to
            // the base class, so `mockPairingURI` there would never see the
            // subclass's port.
            pairingURIs: pairingURIs ?? [Self.mockPairingURI],
        )
        if slowPlacement {
            app.launchArguments += ["-mizarSlowPlacement"]
        }
        if hugeSpacer {
            app.launchArguments += ["-mizarHugeBottomSpacer"]
        }
        if let contentSizeCategory {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", contentSizeCategory]
        }
        app.launch()
        dismissSystemAlertIfPresent(app)
        // Simulator/system relaunches can reopen the app without the runner's
        // arguments. A protocol test seeing the login gate is not exercising a
        // conversation at all: restore the exact offline test launch once.
        if app.buttons["welcome.gate.signIn"].exists {
            app.terminate()
            app.launch()
            dismissSystemAlertIfPresent(app)
        }
        if naming { dismissNamingIfPresented(app) }
        return app
    }

    /// The launch arguments one run of the app is started with.
    ///
    /// Kept apart from ``launch(pairing:session:language:pending:slow:naming:freshStart:)``
    /// so that a test which relaunches the app can say what the *second* launch
    /// looks like. That is the only way to check anything that has to outlive a
    /// process -- a stored pairing, a switch position -- because everything else
    /// in this suite throws the app away between assertions.
    ///
    /// - Parameters:
    ///   - pairing: whether to pass a pairing URI.
    ///   - session: a session to open, or `nil` to stay on the list.
    ///   - language: a language to force, or `nil` to follow the system.
    ///   - freshStart: whether to throw the stored data away first.
    ///   - pairingURIs: the computers to pair with, in order.
    /// - Returns: the arguments.
    static func arguments(
        pairing: Bool,
        session: String?,
        language: String?,
        freshStart: Bool,
        pairingURIs: [String]? = nil,
    ) -> [String] {
        var arguments: [String] = []
        // Repeated, and in order: the app pairs with each in turn, which is how a
        // phone that manages two computers gets that way without a test having to walk
        // the pairing screen twice.
        // Resolved here, not in the default argument, for the same reason
        // ``launch`` resolves its: the default-argument context is bound to
        // the base class and would never see a subclass's port.
        if pairing { for uri in pairingURIs ?? [mockPairingURI] { arguments += ["-mizarPairURI", uri] } }
        if let session { arguments += ["-mizarSelectSession", session] }
        if let language {
            arguments += ["-AppleLanguages", "(\(language))"]
            if language == "en" { arguments += ["-AppleLocale", "en_US"] }
        }
        // The stored conversations outlive a relaunch, which is the point of
        // them -- and means a test that did not ask for a clean one would be
        // measuring an earlier run's fixture merged with this one's.
        if freshStart { arguments += ["-mizarFreshStart"] }
        // The system prompts are real and belong to the app, not to a test:
        // answered by an alert, every assertion after them measures the alert.
        arguments += ["-mizarSkipPermissionPrompts"]
        // The one-time "name this computer" prompt is anchored to the sidebar
        // button and appears when a drawer closes on a conversation; a suite
        // that opens conversations by tapping rows would meet it over the
        // toolbar. The prompt itself is covered by its own test.
        arguments += ["-mizarSkipNaming"]
        // No account in the protocol suite. A session left in the Keychain by
        // the account suite would otherwise make every launch call the
        // production `/me`, and the first screen would be measured through a
        // 30-second timeout. The override also keeps a future signed-in test
        // from reaching the real account server by accident.
        arguments += ["-mizarAccountFreshStart", "-mizarAccountURL", "http://127.0.0.1:\(mockPort)"]
        // The app now opens on a login gate. The protocol and layout suites drive
        // screens behind it and have no account to sign in with, so they launch
        // past it; the gate has its own test class.
        arguments += ["-mizarSkipLoginGate"]
        // Credits come from GitHub; the suite asserts rows, not the network.
        arguments += ["-mizarCreditsFixture"]
        // No splash: the suite looks for its first control within a few seconds
        // of launching, and the splash covers the screen until the first read
        // lands. The operator sees it; the tests do not.
        arguments += ["-mizarSkipSplash"]
        // No splash: the suite looks for its first control within a few seconds
        // of launching, and the splash covers the screen until the first read
        // lands. The operator sees it; the tests do not.
        // The fixture answers on a direct address, and the app's transport
        // switches default to off -- without this every test lands on "The
        // transport switches are off" instead of a conversation.
        arguments += ["-mizarDirectConnection"]
        return arguments
    }

    /// Open the settings, from the gear at the foot of the sidebar.
    ///
    /// Found by identifier and never by its label: the label is 设置 in
    /// Chinese, and a query for "Settings" passes only in one language.
    ///
    /// - Parameter app: the running app.
    func openSettings(_ app: XCUIApplication) {
        openSidebar(app)
        let gear = app.buttons["sidebar.settings"]
        expect(gear, "there is no way to the settings")
        gear.tap()
    }

    /// Bring the sidebar out, if it is not out already.
    ///
    /// Idempotent, because whether it is out depends on how the test launched:
    /// a launch with nothing selected opens it, and opening a session closes it.
    /// The new-session row being hittable is the sidebar being in front -- it is
    /// hidden from the accessibility tree while the conversation covers it.
    ///
    /// - Parameter app: the running app.
    func openSidebar(_ app: XCUIApplication) {
        let marker = app.buttons["sessions.new"]
        if marker.exists, marker.isHittable { return }
        let toggle = app.buttons["shell.sidebarToggle"]
        if !toggle.waitForExistence(timeout: Self.patience) {
            // A system dialog that arrived late covers the shell and eats the
            // tap. Dismiss it and look once more before calling it a failure.
            dismissSystemAlertIfPresent(app)
            if !toggle.waitForExistence(timeout: Self.patience) {
                expect(toggle, "there is no way to open the sidebar")
            }
        }
        toggle.tap()
        let shown = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND hittable == true"),
            object: marker,
        )
        XCTAssertEqual(XCTWaiter().wait(for: [shown], timeout: Self.patience), .completed, "the sidebar did not open")
    }

    /// Put the list of computers away.
    ///
    /// The sheet closes by itself once a switch has landed, so this only taps
    /// Done when it is still there.
    ///
    /// - Parameter app: the running app.
    func closeHosts(_ app: XCUIApplication) {
        let done = app.buttons["hosts.done"]
        if done.waitForExistence(timeout: 2) { done.tap() }
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: done)
        _ = XCTWaiter().wait(for: [gone], timeout: Self.patience)
    }

    /// Bring one card of the waiting deck to the front.
    ///
    /// The dock above the composer shows one request at a time with the others
    /// stacked behind it; "Next" moves through them.
    ///
    /// - Parameters:
    ///   - element: something only that card holds.
    ///   - app: the running app.
    /// - Returns: whether it came forward.
    @discardableResult
    func bringCardForward(_ element: XCUIElement, in app: XCUIApplication) -> Bool {
        // Existence is the front: the cards behind are drawn as edges only, so
        // what one holds is not in the tree until it comes forward. Not
        // hittability -- a long question batch scrolls inside its card, and its
        // last control can be in front and still below the card's fold.
        if element.waitForExistence(timeout: 5) { return true }
        let next = app.buttons["interactions.next"]
        for _ in 0..<4 {
            guard next.exists else { break }
            next.tap()
            if element.waitForExistence(timeout: 2) { return true }
        }
        return element.exists
    }

    /// The control for one switch on the settings screen.
    ///
    /// Three queries, in order, because how SwiftUI exposes a `Toggle` has moved
    /// between OS versions: the classic `switches` query, the newer `toggles`
    /// one -- `XCUIElement.ElementType.toggle` is a separate type -- and finally
    /// any element carrying the identifier, which is what a `List` row does when
    /// the control inside it is not itself exposed. The first version of this
    /// test asked `switches` alone and reported a screen full of switches as
    /// having none.
    ///
    /// - Parameters:
    ///   - identifier: the row's accessibility identifier.
    ///   - app: the running app.
    /// - Returns: the element to tap.
    func settingControl(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        for candidate in [app.switches[identifier], app.toggles[identifier]] where candidate.exists {
            return candidate
        }
        // The identifier reached a row rather than a control. Tapping the row is
        // normally enough -- a `Toggle` row toggles from anywhere on it -- but the
        // control inside is tried first when there is one, because it is the
        // thing the tap is meant for.
        let row = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
        for inner in [row.switches.firstMatch, row.toggles.firstMatch] where inner.exists {
            return inner
        }
        return row
    }

    /// Whether one switch is on, read from whichever element reports it.
    ///
    /// The identifier can land on the control or on the row that contains it, so
    /// both are tried and the value is taken from the first that has one.
    ///
    /// - Parameters:
    ///   - identifier: the row's accessibility identifier.
    ///   - app: the running app.
    /// - Returns: the state, or `nil` when nothing reported one.
    func settingState(_ identifier: String, in app: XCUIApplication) -> Bool? {
        let candidates = [
            app.switches[identifier],
            app.toggles[identifier],
            app.descendants(matching: .any).matching(identifier: identifier).firstMatch,
        ]
        for candidate in candidates where candidate.exists {
            if let state = Self.onValue(candidate) { return state }
            // The identifier reached a row: the state is on something inside it,
            // which may carry no identifier of its own. Bounded, because this
            // walks the accessibility tree of one row.
            let inside = candidate.descendants(matching: .any)
            for index in 0..<min(inside.count, 12) {
                if let state = Self.onValue(inside.element(boundBy: index)) { return state }
            }
        }
        return nil
    }

    /// Tap a switch, aiming at the control rather than at the row.
    ///
    /// `element.tap()` taps the centre of whatever frame the element reports, and
    /// a SwiftUI `Toggle` row is exposed as a switch whose frame is sometimes the
    /// whole row -- so the centre of it is the *label*, and a tap there did
    /// nothing at all. Aiming near the trailing edge lands on the switch in both
    /// cases: it is still inside a switch that reports its own frame, and it is
    /// the switch that lives at the trailing edge of a row that reports the row's.
    ///
    /// - Parameters:
    ///   - control: the element to tap.
    ///   - app: the running app, for nothing but symmetry with the other helpers.
    func flip(_ control: XCUIElement, in app: XCUIApplication) {
        _ = app
        control.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
    }

    /// Wait until a switch reports a different state.
    ///
    /// Polled rather than read once: the write goes through SwiftUI's binding and
    /// comes back as a re-render, which is a frame later than the tap.
    ///
    /// - Parameters:
    ///   - identifier: the row's accessibility identifier.
    ///   - app: the running app.
    ///   - before: the state it had.
    /// - Returns: whether it moved.
    func settingChanges(_ identifier: String, in app: XCUIApplication, from before: Bool?) -> Bool {
        let moved = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in self.settingState(identifier, in: app) != before },
            object: nil,
        )
        return XCTWaiter().wait(for: [moved], timeout: 5) == .completed
    }

    /// A switch's value, as a `Bool`.
    /// - Parameter element: the element to read.
    /// - Returns: whether it is on, or `nil` when it reports nothing.
    static func onValue(_ element: XCUIElement) -> Bool? {
        switch (element.value as? String)?.lowercased() {
        case "1", "on", "true": true
        case "0", "off", "false": false
        default: nil
        }
    }

    /// The element carrying an identifier whose label says something.
    ///
    /// A SwiftUI `Label` puts its identifier on both the text and the symbol --
    /// the symbol's label is "Account" -- so asking for "the" element with an
    /// identifier is ambiguous, and `XCUIElementQuery` throws rather than
    /// choosing. The one whose label contains the expected text is the one
    /// wanted, and both callers here are checking text.
    ///
    /// - Parameters:
    ///   - identifier: the accessibility identifier.
    ///   - app: the running app.
    ///   - text: what the label should contain.
    /// - Returns: the element, or the first match when none says it.
    func labelled(_ identifier: String, in app: XCUIApplication, contains text: String) -> XCUIElement {
        let matches = app.descendants(matching: .any).matching(identifier: identifier)
        for index in 0..<matches.count where matches.element(boundBy: index).label.contains(text) {
            return matches.element(boundBy: index)
        }
        return matches.firstMatch
    }

    /// Scroll the settings window until a row has been built.
    ///
    /// A SwiftUI `List` is lazy in the same way the conversation is: a row below
    /// the fold is not in the accessibility tree at all, and `waitForExistence`
    /// cannot see what the app has not built.
    ///
    /// The settings are a small window out of the gear, so the thing to scroll
    /// is the window and not the screen. A `swipeUp()` carries the list much
    /// further than one row: asking for the Live Activity switch after a flick
    /// found the About section instead, with the switch built and already gone
    /// above the window -- which reads exactly like a missing switch. Short
    /// drags inside the window, one at a time, land on it.
    ///
    /// - Parameters:
    ///   - element: the row to look for.
    ///   - app: the running app.
    ///   - attempts: how many windows' worth to travel.
    /// - Returns: whether it turned up.
    @discardableResult
    func revealInSettings(_ element: XCUIElement, in app: XCUIApplication, attempts: Int = 8) -> Bool {
        if element.waitForExistence(timeout: 3) {
            nudgeIntoView(element, in: app)
            return true
        }
        // Inside the settings window on every phone: it hangs from the gear at
        // the foot of the sidebar, so this band is its content, nowhere near the
        // edges the window can be dismissed from.
        let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.66))
        let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.46))
        for _ in 0..<attempts {
            from.press(forDuration: 0.05, thenDragTo: to)
            // A row that has just been built under a finger still moving is not
            // a tap target yet: the log export was found and tapped in the same
            // tenth of a second once, and the tap landed on the scroll view.
            Thread.sleep(forTimeInterval: 0.45)
            if element.exists, element.isHittable {
                nudgeIntoView(element, in: app)
                return true
            }
        }
        return element.exists
    }

    /// Move a row that was revealed at the window's very bottom edge up a little.
    ///
    /// Being built is not the same as being *in* the window: a row that just
    /// cleared the fold has the row below it unbuilt, and a test that then
    /// expects the next row -- the archive an export produces -- is asking about
    /// something the app has not drawn. One short drag leaves room under it.
    ///
    /// - Parameters:
    ///   - element: the row that was found.
    ///   - app: the running app.
    func nudgeIntoView(_ element: XCUIElement, in app: XCUIApplication) {
        guard element.exists, element.frame.maxY > app.frame.height * 0.72 else { return }
        let from = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.66))
        let to = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.46))
        from.press(forDuration: 0.05, thenDragTo: to)
        Thread.sleep(forTimeInterval: 0.45)
    }

    /// Skip the naming prompt.
    ///
    /// Pairing offers a name once, which is a product feature and not what these
    /// tests are about; a test that leaves it up is a test that measures the
    /// sheet.
    ///
    /// It is offered *after* the first download -- the download is the whole
    /// screen, and a prompt presented over it would be answered blind -- so the
    /// wait has to outlast a download rather than a screen transition. Five
    /// seconds was enough for a transition and not for a download, and the
    /// symptom was an intermittent failure in whichever test ran slowest: the
    /// sheet was still up, covering the screen every assertion was about.
    ///
    /// - Parameter app: the launched app.
    func dismissNamingIfPresented(_ app: XCUIApplication) {
        // Two tries, because the window is presented once the drawers have
        // stopped moving and a launch can get through the first frame before
        // that. The second only happens when the first tap found nothing: a
        // query that existed a moment ago is not a window that is there now.
        for _ in 0..<2 {
            let skip = app.buttons["rename.skip"]
            guard skip.waitForExistence(timeout: Self.namingPatience) else { return }
            guard skip.isHittable else {
                Thread.sleep(forTimeInterval: 0.4)
                continue
            }
            skip.tap()
            if !skip.waitForExistence(timeout: 2) { return }
            Thread.sleep(forTimeInterval: 0.4)
        }
    }

    /// Tap away a system permission alert, if one is up.
    ///
    /// The notification prompt can outlive the process that asked for it: a
    /// launch that is interrupted leaves the dialog on screen for the next one,
    /// where it covers the sidebar and eats every tap under it.
    ///
    /// - Parameter app: the launched app, unused beyond keeping the signature
    ///   parallel with the other launch helpers.
    func dismissSystemAlertIfPresent(_ app: XCUIApplication) {
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        // The dialog can arrive a beat after the app does: it is raised by the
        // app's own first request, not by the launch itself.
        for _ in 0..<3 {
            for label in ["Don’t Allow", "Don't Allow", "Allow"] {
                let button = springboard.buttons[label]
                if button.waitForExistence(timeout: 1), button.isHittable {
                    button.tap()
                    return
                }
            }
        }
        _ = app
    }

    /// Wait for an element to exist.
    /// - Parameters:
    ///   - element: the element.
    ///   - message: what to say when it never appears.
    func expect(_ element: XCUIElement, _ message: String) {
        XCTAssertTrue(
            element.waitForExistence(timeout: Self.patience),
            "\(message) (waited \(Self.patience)s)",
        )
    }

    /// Whether a directory path appears anywhere the operator could tap it.
    ///
    /// Deliberately not by identifier: this has to be able to report the bug it
    /// was written for, and an identifier that does not exist yet would make it
    /// fail for the wrong reason. A path is not a localised string, so matching
    /// on the label is safe here in a way it is not for the rest of this file.
    ///
    /// Scanned by index rather than through an `NSPredicate`: a predicate is not
    /// `Sendable`, and handing one to a query is a data-race error under Swift
    /// 6's region isolation.
    ///
    /// - Parameters:
    ///   - app: the running app.
    ///   - path: the directory to look for.
    /// - Returns: whether it is on screen.
    func offersDirectory(_ app: XCUIApplication, _ path: String) -> Bool {
        if app.buttons.allElementsBoundByIndex.contains(where: { $0.label.contains(path) }) {
            return true
        }
        return app.staticTexts.allElementsBoundByIndex.contains { $0.label.contains(path) }
    }

    /// A turn's row, wherever it is in the tree.
    ///
    /// Found by identifier and by `any` descendant, deliberately. A turn row is
    /// a plain `HStack` of a glyph, some text and a count -- it is not a control
    /// any more, so it is not a button, and which element type SwiftUI gives a
    /// row of loose `Text`s is not something this test should depend on.
    ///
    /// - Parameters:
    ///   - app: the running app.
    ///   - turn: the turn number.
    /// - Returns: the row.
    func turnRow(_ app: XCUIApplication, _ turn: Int) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "turn.\(turn)").firstMatch
    }

    /// Make the mock host's session report itself as stopped, or running again.
    ///
    /// - Parameter running: whether it is running.
    static func setMockSessionRunning(_ running: Bool) {
        guard let url = URL(string: "http://127.0.0.1:\(mockPort)/session?running=\(running ? 1 : 0)") else { return }
        let done = DispatchSemaphore(value: 0)
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        URLSession.shared.dataTask(with: request) { _, _, _ in done.signal() }.resume()
        _ = done.wait(timeout: .now() + 6)
    }

    /// Wait for the sidebar to be out, or away, judged by one of its controls.
    func sidebar(_ marker: XCUIElement, isOut: Bool) -> Bool {
        let format = isOut ? "exists == true AND hittable == true" : "exists == false OR hittable == false"
        let settled = XCTNSPredicateExpectation(predicate: NSPredicate(format: format), object: marker)
        return XCTWaiter().wait(for: [settled], timeout: Self.patience) == .completed
    }

    /// Wait until an element is gone.
    ///
    /// - Parameters:
    ///   - element: what to watch.
    ///   - timeout: how long to wait.
    /// - Returns: whether it went away.
    func waitForDisappearance(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        return XCTWaiter().wait(for: [gone], timeout: timeout) == .completed
    }

    /// Whether the composer's field holds this text right now.
    ///
    /// Read from the field's value rather than by searching the tree: SwiftUI
    /// leaves a typed string in the accessibility tree after the field clears,
    /// so "the text is somewhere" is not the question. This is.
    ///
    /// - Parameters:
    ///   - text: the text to look for.
    ///   - app: the running app.
    /// - Returns: whether the field holds it.
    func fieldContains(_ text: String, in app: XCUIApplication) -> Bool {
        ((app.textViews["composer.field"].value as? String) ?? "").contains(text)
    }

    /// Wait until the composer's field holds this text.
    ///
    /// Polled rather than read once: a write through the binding comes back as a
    /// re-render a frame after the tap that asked for it.
    ///
    /// - Parameters:
    ///   - text: the text to look for.
    ///   - app: the running app.
    ///   - timeout: how long to wait.
    /// - Returns: whether it turned up.
    func waitForField(_ text: String, in app: XCUIApplication, timeout: TimeInterval = 5) -> Bool {
        let field = app.textViews["composer.field"]
        let arrived = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                ((field.value as? String) ?? "").contains(text)
            },
            object: nil,
        )
        return XCTWaiter().wait(for: [arrived], timeout: timeout) == .completed
    }

}
