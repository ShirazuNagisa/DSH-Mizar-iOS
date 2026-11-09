# Snapshot tests

`DSH-MizarTests` is a unit-test target that renders leaf SwiftUI views with
`ImageRenderer` and compares them, pixel by pixel, with reference PNGs committed
next to the tests. It exists to move the *layout and copy* half of UI coverage
off the XCUITest suite, which launches the whole app for every assertion.

The existing UI suite is 80 XCTest methods: **1806.6 s of test execution /
1831 s wall**, an average of **22.6 s per method**. The snapshot suite is six
tests — four snapshot tests with eight rendered references, plus two
identifier-contract tests (the attachment strip's and the composer field's) —
and executes in **0.23–0.43 s in total** on the same simulator runtime — there
is no app launch, no mock host, no navigation.

## Running it

The scheme is `DSH-Mizar-Snapshots`; its test action contains only
`DSH-MizarTests`. It is separate from `DSH-Mizar` on purpose, so this target can
never make the UI suite or a normal Run build slower.

```sh
xcodebuild test \
  -project DSH-Mizar.xcodeproj \
  -scheme DSH-Mizar-Snapshots \
  -destination "platform=iOS Simulator,name=iPhone 18 Pro" \
  -derivedDataPath .devcache/DerivedData \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES \
  -collect-test-diagnostics never
```

Measured on an **iPhone 18 Pro simulator (iOS 27.0, Xcode 27.0) of the same
device type and runtime** as the booted shared device — a private simulator
instance, because the shared one is reserved for UI-test runs (see *Verification
status* below):

| What | Measured | Baseline |
| --- | --- | --- |
| first build, fresh `DerivedData` (MizarKit + app + tests) | 55 s wall | — |
| `xcodebuild test`, incremental build + run | 47 s wall | — |
| build after touching one test file (`build-for-testing`) | 10 s | — |
| `test-without-building` (install + launch + teardown + tests) | 26 s wall | — |
| test execution itself (xcresult / Swift Testing output) | **0.23–0.43 s** | 1806.6 s for 80 XCUITests |
| average per snapshot test | **~0.1–0.4 s** | 22.6 s per UI test |

Most of the 26 s is simulator install/launch/teardown, not the tests: the suite
itself is under half a second.

### Verification status

- The suite and its references were recorded and then re-verified in **compare
  mode** (no `MIZAR_SNAPSHOT_RECORD`) on a private iPhone 18 Pro simulator:
  6 tests / 10 references pass in **0.23–0.43 s**.
- On the shared iPhone 18 Pro, one run connected and passed 5 of 6 tests. Two
  environment problems made the rest of that verification impossible to finish
  here, both external to this target:
  - Another `xcodebuild` test session on the same simulator kills the test host
    (`Test crashed with signal kill before establishing connection`), and a
    session that starts around the same time leaves `testmanagerd` wedged
    (`The test runner hung before establishing connection`, ~5 minutes). If that
    happens, run when the device is idle, and restart the daemon first:
    `xcrun simctl spawn <udid> launchctl kickstart -k system/com.apple.testmanagerd`.
  - The one view that differed on the shared run was `ModelPill` (the pill was
    uniformly ~1% narrower, i.e. rendered mid-transition). The harness now
    disables animations in the render transaction (see below); **cross-device
    re-confirmation of that fix is the one thing left to run** once the simulator
    is free. The other nine references matched across both simulator instances.

## Recording references

Recording is explicit and per-run. It is never triggered by a mismatch:

```sh
xcodebuild test ... MIZAR_SNAPSHOT_RECORD=1
```

`MIZAR_SNAPSHOT_RECORD` is a build setting at the end of the command line; the
scheme passes it through to the test process (`LaunchAction` expands
`$(MIZAR_SNAPSHOT_RECORD)`), and the harness records only when the environment
variable it sees is exactly `1`.

What recording does:

1. Renders each view at the size and scale the test asked for.
2. Writes `DSH-MizarTests/Snapshots/__Snapshots__/<Name>@2x.png`.
3. Prints `[snapshots] recorded <file> (<w>x<h> px)`; the test passes.

**Review the PNGs before committing them.** They are the assertion — a reference
recorded from a regression is a test that will happily pass forever. Recording
overwrites an existing reference; not recording never does.

A normal run (no `MIZAR_SNAPSHOT_RECORD`) compares against the references. A
missing reference is a failure; so is a different pixel size. On a mismatch the
actual render and a magenta diff are written to
`DSH-MizarTests/Snapshots/__Snapshots__/__Failures__/` (git-ignored) and the test
fails with the path, the differing-pixel count and the first differing pixel.

## The harness, and why it is hand-written

`DSH-MizarTests/SnapshotHarness.swift` is ~300 lines: render, encode PNG, decode
PNG, compare RGBA buffers, write artifacts. The decision:

- **No swift-snapshot-testing.** This project has zero package dependencies on
  purpose: `scripts/ios.sh` documents that Xcode resolves a package by loading
  its manifest through `swift-plugin-server`, which writes a diagnostics file
  under `~/Library/Caches/org.swift.swiftpm`; there is no build setting that
  relocates it, so a package reference cannot resolve under the restricted file
  policy the build runs under. Adding the library would also add a second
  rendering/comparison pipeline, its own recording workflow and its own
  tolerance rules for something small enough to own.
- **No Prefire** (excluded by the task, same reasoning plus it is preview-based
  and would not give exact-size, exact-pixel references).
- **The tradeoff:** no automatic diffing service, no perceptual/structural match,
  no per-device reference sets, and the tolerance model is one channel delta
  plus one differing-pixel fraction instead of a library's heuristics. What we
  keep: no dependency, references reviewed in the same `git diff` as the code,
  and a failure message that names the pixels.

Every render is pinned to the same environment so two runs of the same test are
comparable: light colour scheme, `.large` dynamic type, `en_US` *formatting*
locale, 2x display scale, white opaque canvas, and **animations disabled**
(`transaction.disablesAnimations = true`). The last one is not a nicety: a view
carrying a transition — `ModelPill`'s `.blurReplace`, for example — otherwise
renders at whatever insertion progress it reached, which depends on scheduling
and changed `ComposerControls-labelled` between two simulator instances by ~9% of
its pixels at a uniform ~1% scale. Colour and geometry changes are
caught exactly; the default tolerance allows at most 0.1% of pixels to differ by
more than 2/255 (antialiasing at text and shape edges), which is far below what a
1-pt layout shift or a colour change produces.

A second language's golden comes from passing `locale:` (for example
`Locale(identifier: "zh-Hans")`) to the render and assert helpers; the default
stays `en_US`, so every existing reference is unaffected. `Text(LocalizedStringKey)`
follows that locale; fixture data does not translate itself — the test decides
what the content says.

### What the tolerance is not a licence for

- **Changing a fixed size** fails on dimensions before pixels are compared.
- **Changing text, spacing or colour** moves far more than 0.1% of pixels.
- **A blank render** compares blank against blank: see the `ImageRenderer`
  limits below, which is why a blank reference is a bug worth seeing in review.

### The identifier/copy contract

SwiftUI does not expose its accessibility tree to a unit-test process (that tree
is what XCUITest talks to through the accessibility server), and `ImageRenderer`
discards accessibility information. So the snapshot proves the pixels, and
`AppSourceContract` proves the other half: the exact
`.accessibilityIdentifier("…")` literals and `String(localized: "…")` copy the
migrated XCUITest queried are still declared in the view's source in this
checkout. Deleting or renaming one fails the unit test, which is the part of the
XCUITest's assertion a snapshot cannot make.

This is a deliberate, documented stopgap: it checks the app's source, not the
running accessibility tree. A future source extraction (see below) can replace
it view by view.

## What can and cannot be snapshotted

`ImageRenderer` draws SwiftUI's own drawing; it does not render views backed by
UIKit. Verified here rather than assumed:

- **`AttachmentStrip` is blank.** The composer's attachment row is a
  `ScrollView`, which is UIKit-backed, and the recorded reference was an empty
  rectangle. Its pilot is therefore the identifier contract only; the snapshot
  half needs the chip extracted into a view the renderer can draw (or a
  UIHostingController-based renderer, which this harness does not have). Do not
  re-add a blank reference for it.
- **`ComposerTextInput` is blank.** The composer's field is a `UITextView`
  behind `UIViewRepresentable` (replaced 2026-10-22, see
  `docs/ios-three-issues-diagnosis-2026-10-22.md`), which is UIKit-backed the
  same way. Its pilot is the identifier/copy contract only; the long-text
  behaviour it exists for -- viewport, caret following, scroll range -- needs a
  real window and a keyboard, which is UI-test territory.
- **Animations cannot be snapshotted.** `TwinStar`, `MizarMarkConnecting`,
  `MizarMarkSearching` and the live `ConnectionDot` animate, and Reduce Motion —
  the state in which they rest — cannot be forced from a test because
  `accessibilityReduceMotion` is a get-only environment key. `MizarMark`'s static
  `lit` values and the offline `ConnectionDot` are the deterministic states that
  were piloted.
- **Localisation is part of the reference.** `String(localized:locale:)`'s
  `locale:` argument only formats interpolations; it does not choose a
  translation. The fixtures resolve English through the app bundle's `en.lproj`
  explicitly, so a reference recorded on a Chinese-language simulator says
  exactly what one recorded on an English-language simulator says. A view that
  renders `Text("some key")` internally resolves against the render's *locale
  environment*: the harness `locale:` parameter pins that directly, which is
  how the zh/en language goldens are produced without touching the
  simulator's language.
- **The reference belongs to an OS.** Text rasterisation and SF Symbols change
  between iOS releases. An OS upgrade may require a deliberate re-record; a
  cross-runtime mismatch is expected, not a bug.

## Current pilots

| Test | View | Reference | Size (px @2x) |
| --- | --- | --- | --- |
| `MizarMarkSnapshotTests.mizarMark` | `Design/MizarMark` (full, partial fill) | 2 PNGs | 136×92 |
| `AccountAvatarSnapshotTests.accountAvatar` | `Account/AccountScreen.AccountAvatarView` (signed out, Apple monogram, server palette) | 3 PNGs | 88×88 |
| `SettingsAccountRowSnapshotTests.settingsAccountRow` | settings account row: `AccountAvatarView` + name/plan copy (signed out, paid) | 2 PNGs | 780×128 |
| `MarkdownTableSnapshotTests.longCellsWrapInsideTheirColumn` | `Conversation/MarkdownMessage.MarkdownTableGrid` — long Latin + CJK cells | 1 PNG | 1008×1040 |
| `ComposerControlsSnapshotTests.composerControls` | `ModelPill` + `ContextRing` (labelled, compact) | 2 PNGs | 520×80 |
| `ConnectionDotSnapshotTests.connectionDotOffline` | `Shell/ConnectionPanel.ConnectionDot`, offline | 1 PNG | 68×68 |
| `AttachmentStripSnapshotTests` | `Composer/AttachmentStrip` — identifier contract only | — | — |

The settings row's layout itself is a private computed property inside
`SettingsView`, so the pilot reconstructs the row from the app's own
`AccountAvatarView` and the same English copy, and pins the row's identifiers and
copy literals against the directory's source
(`DSH-Mizar/Views/Settings/SettingsView.swift`). It covers what
`AccountUITests.testSignedOutSettingsShowsBlankAccountRow` asserts except the
`List` chrome; it is **not** a full replacement until the row is extracted.

The Markdown table is snapshotted as its grid, without the horizontal
`ScrollView` the conversation puts around it: the scroller is UIKit-backed, and
the truncation it caused (a scroller proposes an unspecified width, so the grid
measured one line) was precisely why the wrapping bug had no reference. The
grid is the layout under test; the scroller is unchanged around it.

## Migrating the UI suite

The cheap ones first — static layout/copy assertions that already have a
snapshot-shaped view, with the exact lines to replace:

1. `DSH-MizarUITests/AccountUITests.swift:59` —
   `testSignedOutSettingsShowsBlankAccountRow`. Pilot already covers the row
   content and copy; extract `SettingsView.accountSection`'s row to a view to
   drop the launch.
2. `DSH-MizarUITests/AppFlowTests.swift:1479` —
   `testTheComposerBarShowsTheModelContextAndCommands`. Pilot covers the pill
   label, the ring's drawing and the two identifiers; the host-supplied `35%`
   value still needs a fixture/unit test of the model.
3. `DSH-MizarUITests/AppFlowTests.swift:2053` —
   `testAPendingApprovalOffersExactlyTwoOutcomes`. `ApprovalCard` takes a
   `PendingApproval` fixture and draws two fixed buttons; snapshot the card and
   pin `approval.reject` / `approval.allowOnce`.
4. `DSH-MizarUITests/AppFlowTests.swift:1032` —
   `testTheAboutSectionShowsTheVersionAndBothCredits`. Version and two credit
   rows are static copy plus layout; extract the rows and snapshot with injected
   `AppEnvironment` values (version must stay a fixture, not the build's).
5. `DSH-MizarUITests/AppFlowTests.swift:1068` —
   `testTheSettingsScreenFollowsTheLanguage`. Snapshot the settings surface once
   per language (one reference set per `lproj`); this needs the language pinned
   explicitly, which the current harness does not do for `Text("key")` — the
   infrastructure is one helper away.

Not first, because they assert interaction or navigation rather than appearance:
`AppFlowTests.swift:910` (`testTheSidebarOpensSettings`),
`AccountUITests.swift:232` (attachments stay locked/unlocked through the composer
and account screens).

## Adding a snapshot

1. Add a `@MainActor` Swift Testing test under `DSH-MizarTests/SnapshotTests/`.
2. Build the view from fixtures (`SnapshotFixtures`) — never from `AppModel`.
3. Call `SnapshotHarness.assertSnapshot(of:named:size:)` with a name that names
   the case, and the exact point size.
4. Assert the returned `pixelWidth`/`pixelHeight` explicitly, so a changed size
   is a readable failure.
5. Record: `xcodebuild test ... MIZAR_SNAPSHOT_RECORD=1`.
6. Open the PNG. If it is blank, the view is not renderable this way — fix the
   view's shape or drop the snapshot, do not commit the blank.
7. Run without the variable, then commit the test and the PNGs together.

## Routing caveat

Per `iOS/AGENTS.md`, a change under the Xcode project/schemes is a forced-full
trigger for `scripts/test-select.sh`: until `test/` maps this target, a diff that
touches `DSH-Mizar.xcodeproj` or the new scheme still makes selection fall back
to the whole UI suite. Wiring `DSH-MizarTests` into the selection script and
giving the migrated UI tests an impact-map entry is a separate change, outside
this target's files.

2026-10-21 于规范设备 Mizar Runs 重录 ComposerControls-labelled 基准（跨实例文本栅格 ~1px/9.3% 差异，重录后套件全绿：7/7，第 7 项为当日并行会话新增的 SubagentPageContract 契约测试）。
