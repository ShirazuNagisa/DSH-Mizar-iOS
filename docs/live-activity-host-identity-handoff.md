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

## 真实审批验收(2026-11-17)

本轮只做验收，未改应用源码、未 commit/push、未安装新包、未重跑测试。

- 手机：`xcrun devicectl list devices` 显示 `00008140-001E48E21813C01C` connected（iPhone 16 Pro）；`devicectl device info apps` 显示 `me.shirazu.dshmizar 0.9.11 (40)` 已安装，版本未变。
- 工作树：`codex/live-activity-production` @ `1326741`，除未跟踪 `node_modules` 外干净；本机 AGI Mizar 0.9.2 在运行，未影响其他 DSH 会话。
- DSH 侧只读筛选专测会话 `session-650d82a3-…`（标题「Mizar Live Activity 审批验证」）：两次 `echo 'Mizar Live Activity 验证'` 的 `bash` 审批请求（`cdad81b0…` 15:46:15、`d55549f9…` 23:44:18）在本地被 **cancelled**（对应 turn 结束原因 aborted/user，18:48:34 与 00:25:28），**不是手机端的 allow/reject**；工具结果均为 `isError=true` + `AbortError/ABORTED`，没有 exit=0 或固定 stdout。当前该会话**没有 pending 审批**。
- 扫描 2026-11-16 之后修改的全部 DSH 会话（仅精确匹配命令原文）：只有上述测试会话和本验证会话命中，没有第三个待批 echo。
- 结论：真实审批闭环**未通过**（pending 已不存在且无可核实成功记录）。未调用任何 answer/approve 接口，未伪造回执；证据 `docs/evidence/ios-live-activity-redesign-2026-11-15/identity-fix/real-approval-check-2026-11-17.json`（根仓库，已脱敏）。
- 最小下一步：在专测会话里重新发出同一条 `echo` 请求（`approval/policy=ask`），手机在「Mizar Live Activity 审批验证」卡片核对命令后点「允许一次」，再以手机 accepted 回执 + pending 消失 + 工具结果 exit=0/stdout 三项联合判定。本轮按约束未自动重试。

## 待审批已就绪(2026-11-17 13:48 +08:00)

本轮只准备请求，不改源码/版本，不安装、不重启、不跑测试，也不调用 answer/approve。

- 专测会话 `session-650d82a3-afda-4603-9af1-51b6c143afaa`（标题「Mizar Live Activity 审批验证」，cwd `/Users/shirazu/Documents/deepseek-harness/default-workspace`）在发送前为 `phase=idle`、`approvalPolicy=ask`、权限 preset `workspace-write`、模型 `opencode-go/deepseek-v4.1-flash`（effort max），无 pending，也无同命令成功记录。
- 通过运行中的 DSH desktop host 的进程内 SDK `sessionController.prompt`（与 Web GUI Remote 同一方法）发送一次正常用户输入，`requestId=78631f50-0c2d-4396-b763-be0404d80f87`；turn 4 于 13:48:45.305 开始。
- 13:48:50.362 产生唯一一次 `bash` 工具调用 `call_00_zpxskt6tuiidyzgxdtusp48i`，参数完全等于：`{"command":"echo 'Mizar Live Activity 验证'","description":"输出固定验证文本，请求手机审批","justification":"仅输出固定验证文本","sandbox_permissions":"danger-full-access"}`。
- 13:48:50.366 产生 `approval/asked`：`id=b256a428-6bc7-4420-bfc5-a4d76d88b785`，`toolName=bash`，`reason=escalate sandbox to danger-full-access: 仅输出固定验证文本`。截至 13:52 仍 `turnOpen=true`、`phase=running`，无 `approval/decided`。
- `dsh-mizar` 插件链路自 12:59:54 起为 link up（`127.0.0.1:58420 -> 127.0.0.1:58378`），请求由插件以 `open`/`answer` 路径交给桌面与手机，不是留在 DSH GUI 的本地卡片。
- 手机 `00008140-001E48E21813C01C` connected，`me.shirazu.dshmizar 0.9.11 (40)`，主 App PID 57215 与 Live Activity 扩展 PID 57207/57523 均在运行；未 terminate/重启/重装。
- 未做手机端决定，未写“验证通过”。就绪证据：根仓库 `docs/evidence/ios-live-activity-redesign-2026-11-15/identity-fix/ready/echo-pending-readiness-2026-11-17.json` 与本 turn 摘录 `target-session-turn4-excerpt-2026-11-17.json`。
- 下一步：用户在手机「Mizar Live Activity 审批验证」卡片核对上列固定命令后点「允许一次」，再由父会话核验 accepted/ack、pending 消失与 `exit=0` + 固定 stdout。手机端 console 需重启 App 才能附加，本轮未附加，故无手机侧日志。

## 真实审批一次放行(2026-11-17 13:56 +08:00)

本轮只读核验，不改源码/版本、不构建、不安装、不重启 App、不跑测试、不调用 answer/approve。

- 精确对象仍是专测会话 `session-650d82a3-afda-4603-9af1-51b6c143afaa`（标题「Mizar Live Activity 审批验证」）、turn 4、`requestId=78631f50-0c2d-4396-b763-be0404d80f87`、`callId=call_00_zpxskt6tuiidyzgxdtusp48i`、`approvalId=b256a428-6bc7-4420-bfc5-a4d76d88b785`；没有扫描或改动其他会话。
- DSH 持久记录（只读解压 session.v4.jsonl.zstd）显示：13:48:50.366 `approval/asked`，13:56:10.829 **同一 approval id** 的 `approval/decided`，`outcome=allowed-once`；随后 13:56:10.830/832 `job/registered` → `job/settled status=completed detail="exit code: 0"`，同一 `toolCallId` 的 `tool/result` 为 `isError=false`、结果文本 `Mizar Live Activity 验证\n`，turn 4 于 13:56:25.260 `completed`。没有后续新的 pending。
- 手机侧：用户在手机上点「允许一次」来自父会话的用户确认；本轮未捕获手机端原始 accepted/ack 日志（附加 console 需重启 App，被禁止），因此不声称抓到客户端日志，也不把 DSH 内部时间当成端到端延迟。桌面实际回执以 DSH 记录为准。
- 结论：**本次单条 echo-only 实测的 DSH 侧审批闭环通过**（same approval → allowed-once → pending 消失 → same toolCall exit=0 + 固定输出）。范围仅限本分支 `1326741`、已装 `0.9.11 (40)`、本机与本次运行；不覆盖其他设备/字号、全 UI/Island 系统呈现、后端或发布验收。
- 证据：根仓库 `docs/evidence/ios-live-activity-redesign-2026-11-15/identity-fix/echo-approval-verified-receipt-2026-11-17.json`（脱敏，保留 readiness 原文件）。
- 历史条目解释：上文「真实审批未验通」「echo 仍 pending」「未做手机端决定」等是各自时点的记录，不回改；本条只说明这次 pending 已由 `allowed-once` 解决，其他未完成项（full UI、跨设备矩阵、release）不因本条自动关闭。
