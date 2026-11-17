# Live Activity host identity handoff

Date: 2026-11-17
Worktree: `/Users/shirazu/Documents/project/DSH-Mizar-iOS-live-activity-impl`
Branch: `codex/live-activity-production`
HEAD: `cee3538` (all work below is uncommitted)

## Model / channel

- DeepSeek V4.1 Flash in DeepSeek Harness (opencode-go subscription route); no OpenAI/ChatGPT model, no subagents.
- No commit, push, deploy, install of the follow-up build, phone interaction, desktop restart, or approval action.

## Changes

- `MizarKit/Sources/MizarKit/LiveActivityHostIdentity.swift` (new)
  - `canBootstrap` only for account pairings: `host.hostId == host.deviceId`, non-empty `accountId` and session header, relay endpoint, and an exact official account relay.
  - Official relay validation reuses `RelayTier.isPaidRelay` / `canonicalOrigin`: HTTPS unified 443 (no port or explicit `:443`) or legacy `:8443`; rejects arbitrary ports, self-hosted relays, userinfo, query, and fragment.
  - Binding key is a SHA-256 of host ID + device ID + credential digest; the stored value is only the public canonical ID. No token is stored.
  - First bind is fixed for that credential generation; a later canonical change is refused; a rotated credential gets a new key and cannot inherit the old pin.
  - `resolvePairedHost`: a unique exact `PairedHost.hostId` wins (QR/legacy record), otherwise a unique canonical alias; multiple pure aliases remain ambiguous and resolve to nil. No name matching or probing.
- `MizarKit/Sources/MizarKit/LiveActivityHostConnection.swift`
  - Session header is retained only for the validated official account relay.
  - On connect, resolve the credential-generation pin and require `welcome.hostId` equality; bootstrap only when no pin exists and `canBootstrap` passes.
  - Existing DEBUG route diagnostics retained.
- `MizarKit/Sources/MizarKit/LiveActivityAnswers.swift`
  - `target` resolves canonical IDs through current authorized bindings; the action still uses the paired host and keeps exact host/session/request preflight and accepted/unknown semantics.
- `DSH-Mizar/App/MultiHostLiveActivityMonitor.swift`
  - Rows and approvals carry the `welcome` canonical host ID; snapshot and push-registration caches remain keyed by the pairing alias.
  - Deduplicates rows by canonical host + session and approvals by canonical host + request. A live copy wins over an offline cache; non-overlapping offline rows/approvals are kept.
  - Offline cached approvals are re-emitted with `requiresDetail = true` so a mixed narrow-scope online account cannot make another scope's cached approval directly actionable. No protocol or RPC change.
- `DSH-Mizar/App/LiveActivityDetailView.swift`
  - Canonical deep-link host IDs resolve through a unique exact `PairedHost.hostId` first, then a unique canonical alias. Internal snapshots stay alias-keyed.
  - A failed 4-second poll now keeps the last confirmed `sessions`, `pending` and `messages`, and marks the screen with the existing localized "Could not refresh" instead of replacing valid context with nil.
  - Approval send reuses `LiveActivityAnswers.send` on its own exact connection (canonical resolve, pending preflight, accepted/unavailable/unknown semantics); it does not queue behind this screen's `session.list` / `session.messages`.
  - Recheck opens its own exact connection. Accepted answers update the local resolved overlay and shared feedback; rejected/unavailable/unknown never write success. Unknown only offers recheck, no automatic retry. Re-entry guards and leave-time disconnect remain.
  - Overview deduplicates active rows by canonical + session and offline labels by canonical; it does not treat a narrow-scope online account as authoritative for the whole host.
- `MizarKit/Tests/MizarKitTests/LiveActivityHostIdentityTests.swift` (new)
  - 9 focused tests, including the account+QR same-machine counterexample, exact-match precedence, pure-alias ambiguity rejection, official 443/8443 acceptance, unsafe URL rejection, credential-generation pinning/rotation, metadata token absence, and header scoping.

## Real-device observation and detail polling fix (2026-11-17)

The canonical-identity package was installed on the real phone. The user observed the real echo pending approval, two other real sessions at the same time without duplicates, and the Island opening the exact approval detail. The echo request remains pending; no decision was made.

A detail-only bug remained: the first screen showed the real Bash reason, the 23:44 request time and the test session, but a 4-second poll RPC timeout made `refreshHost` replace `sessions`/`pending` with nil. The whole page switched to "Could not verify" and the buttons disappeared while scrolling. The main model confirmed this from the screenshot.

The fix is confined to `LiveActivityDetailView.swift`:

- Keep the last confirmed `sessions`, `pending` and `messages` on a failed refresh and show `Could not refresh` (existing localized copy) instead of clearing context.
- Send decisions through `LiveActivityAnswers.send` on an independent exact connection; preflight, accepted/unavailable/unknown and logging stay in that shared path. No queueing behind the detail screen's reads.
- Recheck opens its own exact connection. Only `.accepted` updates the local resolved overlay and feedback; other results do not fake success. Unknown only offers recheck.
- No ID, layout or protocol change; anti-reentry and leave-time disconnects are unchanged.

## Verification

- Focused tests (latest):
  - `cd MizarKit && swift test --filter 'LiveActivityHostIdentityTests|LiveActivityRoutingTests'`
  - 26 tests / 2 suites passed, 0 failed; log `/tmp/mizar-live-detail-stale-targeted-tests.log`.
- Latest incremental signed iPhone build:
  - Command: `xcodebuild -project DSH-Mizar.xcodeproj -scheme DSH-Mizar -configuration Debug -destination 'platform=iOS,id=00008140-001E48E21813C01C' -derivedDataPath .devcache/final-frozen-iphone-build/DerivedData -allowProvisioningUpdates DEVELOPMENT_TEAM=5Q2A46685M CODE_SIGN_STYLE=Automatic CODE_SIGNING_ALLOWED=YES OTHER_SWIFT_FLAGS='-disable-sandbox' build`
  - `** BUILD SUCCEEDED **`, 0 errors; log `.devcache/final-frozen-iphone-build/identity-detail-stale-incremental-build.log`.
  - App: `.devcache/final-frozen-iphone-build/DerivedData/Build/Products/Debug-iphoneos/DSH-Mizar.app`.
  - `codesign --verify --deep --strict` valid; Team `5Q2A46685M`; Apple Development `844949851@qq.com`; version `0.9.11` (40) unchanged.
  - The phone was connected as `00008140-001E48E21813C01C` for this build; no install was attempted.
- Not run: full package suite, UI suite, 90-size matrix, install, or real phone approval.

## Unfinished / next

- [ ] Install the follow-up detail build when the user chooses; then verify scrolling through the real pending approval with a poll timeout. The real echo decision is still pending and must not be recorded as passed.
- [ ] Full UI/package coverage and the 90-size matrix remain intentionally unrun for this focused change.
- [ ] Unpair does not delete the identity metadata; the key includes the credential digest, so a re-pair with a new credential gets a fresh pin.
- No commit or push. Review the worktree with `git -C /Users/shirazu/Documents/project/DSH-Mizar-iOS-live-activity-impl diff` plus the untracked `LiveActivityHostIdentity.swift`, `LiveActivityHostIdentityTests.swift` and this handoff.

## Pause checkpoint (2026-11-17)

Paused at the explicit request of the user, who needs the phone. The dedicated DSH OpenCode Flash repair session is idle. No further phone interaction is authorized until the user resumes. The latest detail-refresh build was installed and launched successfully by the parent; its final real approval check was interrupted by this pause.

Confirmed before pausing: account/canonical identity matching recovered; the phone showed the real echo approval alongside two other active sessions without duplicate rows; the Dynamic Island link opened the exact echo approval. A later poll timeout cleared the old detail screen, and the follow-up patch preserves cached context and uses independent decision/recheck connections. Its 26 targeted tests and signed incremental build passed; the parent separately passed nine identity tests. The follow-up build is installed, but no final Allow/ack/echo-output cycle has been verified. Last observed test state was pending. No full suite or size matrix was rerun for this fix, and no version was changed.

Resume by checking the connected phone and the original echo-only test session. Do not restart design work, official subagents, or full suites. Use DSH's existing DSH-Mizar workspace and opencode-go DeepSeek V4.1 Flash; the user authorized full permission for subsequent worker sessions.
