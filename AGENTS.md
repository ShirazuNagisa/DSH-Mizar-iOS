# DSH-Mizar iOS — notes for coding agents

Read the project's `README.md` §四 for the plain commands. This file only lists
rules that keep the test loop cheap and safe. Current state, measured numbers,
blockers and rollback: `docs/test-pipeline-handover.md` (2026-10-20).

## Building and testing on a machine with a nested sandbox

`xcodebuild`'s Swift macro plugin (`swift-plugin-server`) sandboxes itself, and
that fails under a sandboxed shell with `produced malformed response`. Pass the
flag through to the compiler:

```sh
OTHER_SWIFT_FLAGS='-disable-sandbox' scripts/ios.sh build
OTHER_SWIFT_FLAGS='-disable-sandbox' scripts/ios.sh test-fast
```

Without it, every `@Observable`/`@State` in the app target fails to compile and
the errors point at "cannot find `$foo` in scope" -- which is the macro failing,
not the view.

## Test loop

```sh
scripts/test-select.sh              # default: diff vs origin/main + worktree, run only what it can prove is affected
scripts/test-select.sh --dry-run    # print the selection plan and the reasons, run nothing
scripts/test-select.sh --full       # ignore selection: unit suite + whole UI suite
scripts/test-select.sh --files a,b  # selection hook for a synthetic diff (verification)
```

- The MizarKit unit suite always runs whole (`scripts/swift.sh test`, host,
  ~6s). Do not try to select inside it.
- The UI suite is 80 XCTest methods / 9 classes and takes 20–25 minutes whole.
  It is only narrowed when `test/impact-map.json` (generated from a real full
  run) or an explicit route in `test/test-routing.json` names the tests that
  reach the changed file.
- Anything that is not provably local to one screen falls back to the whole
  suite ("fallback:" lines in the output). Do not silence that.
- Layering: the default run is the replay layer (`MIZAR_TEST_MODE=replay`,
  exported by `test-select.sh`). Live tests skip loudly unless the run is
  explicitly live (`scripts/test-select.sh --live`). Never make a default run
  hit a real host or a live model.
- If the model picks a subset by hand, it must still list the tests it did not
  run in the reply. Never imply a subset was a full run.

## Forced-full triggers (already enforced by test-select.sh)

Changes under: the Xcode project/schemes/test plans, `MizarKit/Sources`,
`MizarKit/Package.swift`, `protocol/`, `scripts/`, `test/`, `package.json`,
`DSH-Mizar/App/`, `DSH-Mizar/Design/`, localization/asset/plist/entitlement/
storekit resources, the Live Activity target, or any unknown file. Also when the
UI test count no longer matches `expectedUiTests` in `test/test-routing.json`
(new or removed tests) or the impact map mentions tests that no longer exist.
`DSH-MizarTests/` changes are not mapped by `test-select.sh` yet, so they hit the
unknown-file full fallback until the snapshot target is wired in (phase 3).

## Snapshot suite (layout/copy, no app launch)

`DSH-MizarTests` (scheme `DSH-Mizar-Snapshots`, separate from `DSH-Mizar`) renders
leaf SwiftUI views with `ImageRenderer` and compares reference PNGs in
`DSH-MizarTests/Snapshots/__Snapshots__/`. Six tests / ten references execute in
about 0.3 s, against 22.6 s per XCUITest. Record only deliberately with
`MIZAR_SNAPSHOT_RECORD=1`; a missing reference fails and a mismatch never
rewrites one. Command and limits: `docs/snapshots.md`. XCUITest keeps the key
business flows; the migration plan (80 -> <=16 kept) is `docs/phase2-triage.md`.

## Replay: no real network

HTTP is replayed from HAR fixtures in `protocol/fixtures/http/` by
`MizarKit`'s `HTTPReplayTransport` (`docs/http-replay.md`); regenerate
deterministically with `scripts/record-http-fixtures.sh`. A miss throws — there
is no network fallback. The app's default transport is still the real
`URLSessionHTTPTransport`; selecting replay inside the app is opt-in and not
wired yet. The UI suite talks to the local mock host on 127.0.0.1:19395/19396.

## Live layer

Preserved and explicitly triggerable: MizarKit's `LiveNetworkTests` (and future
UI live tests) skip unless `MIZAR_TEST_MODE=live` plus the environment values
(`MIZAR_LIVE_BASE_URL`; UI live tests would use `MIZAR_LIVE_PAIRING_URI`).
`scripts/test-select.sh --live` sets both the runner variable and its
`TEST_RUNNER_` copy. The default regression must never run the live layer.

## Adding coverage for a new screen

1. Add/extend a UI test class (`DSH-MizarUITests/…`), run the full suite once.
2. Regenerate `test/impact-map.json` with `scripts/record-impact-map.sh`
   (per-test coverage; one-time, ~30–40 min).
3. Bump `expectedUiTests` in `test/test-routing.json` if tests were added.
4. Re-run `scripts/test-select.sh --dry-run --files <changed path>` and check
   that the class shows up under "mapped:".

Until a file is in the impact map, changing it means a full run — that is the
zero-miss default, not a bug.

## Rollback

Phase commits are single-purpose commits on `main`; revert with
`git revert <sha>` (no data migration, no project-file edits).

## Workspace wiki

- 工作区根有本地预编译 Wiki：动 iOS 代码前先 `wiki search "<模块/错误关键词>" --scope ios`（等价 `node ../tools/wiki/bin/wiki.mjs search "..." --scope ios`）。
- 规则、状态含义与 MCP 配置见根 `AGENTS.md` 的「本地 Wiki」节与 `docs/wiki/quickstart.md`（工作区根下）。
