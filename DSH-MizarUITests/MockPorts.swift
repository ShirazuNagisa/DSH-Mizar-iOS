//
//  MockPorts.swift
//  DSH-MizarUITests
//
//  One mock-host pair per UI test class. A mock's state is process-global --
//  /reset, /offline, /hold and every counter reach each of its clients -- so
//  two test classes sharing one host erase each other's fixtures mid-run.
//  Giving every class its own primary port is what makes class-parallel UI
//  runs possible at all.
//
//  Layout per class: the primary on the table's port, the second machine on
//  port + 1, and one relay stand-in per machine on port + 2 and port + 3
//  (mock-host.mjs derives both from the port it is given). Four apart, so
//  neighbouring classes cannot collide.
//
//  The port marker line below is the single source of truth for the
//  shell: scripts/ios.sh and scripts/record-impact-map.sh parse it to start
//  every host. A port changes here, and nowhere else.
//

// mock-ports: 19400 19404 19408 19412 19416 19420 19424 19428 19432 19436 19440 19444 19448 19452 19456 19460 19464

enum MockPorts {
    /// Primary mock-host port per UI test class. The keys are class names,
    /// which are also the file names -- the selectors and the impact map key
    /// off the file name, so the two can never drift apart.
    static let classPorts: [String: Int] = [
        "AppFlowLaunchTests": 19400,
        "AppFlowSessionDetailTests": 19404,
        "AppFlowTurnLifecycleTests": 19408,
        "AppFlowNavigationTests": 19412,
        "AccountUITests": 19416,
        "ActivityUITests": 19420,
        "Feature094UITests": 19424,
        "ForkedSessionUITests": 19428,
        "LANFailoverUITests": 19432,
        "LanPriorityUITests": 19436,
        "RunningDetailUITests": 19440,
        "ScreenshotTour": 19444,
        "WelcomeGateUITests": 19448,
        "PreviewPaneUITests": 19452,
        "LocalAgentUITests": 19456,
        "Feature099UITests": 19460,
        "ConversationImagesUITests": 19464,
    ]

    /// The primary mock port for `className`; the second machine answers on
    /// port + 1 and the relay stand-ins on port + 2 and + 3. A name the table
    /// does not list falls back to the historical default, 19395.
    static func port(for className: String) -> Int {
        classPorts[className] ?? 19395
    }
}
