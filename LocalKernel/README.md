# Mizar LocalKernel — 本地 Agent 内核

在手机和平板上运行 DSH 式 Agent 的本地内核：**与 GUI 解耦、iOS 与 Android
复用同一份 TypeScript 核心、与桌面端宿主说完全相同的 Mizar 协议 v1**。

```
GUI ──协议帧──> LocalKernelTransport ──> TypeScript 内核 ──PlatformHost──> 平台能力
                (WebSocketTransport)      (JS 引擎内)      (fs/http/kv/定时器)
```

- **协议契约**：`docs/kernel-api.md` —— 内核的完整对外通信 API（GUI 接入
  以此为准）。
- **架构与决策**：`docs/kernel-architecture.md` —— 设计取舍、桌面端代码
  复用清单、引擎适配指南。

## 目录

```
LocalKernel/
  kernel/                        ← 平台中立的 TypeScript 内核（核心资产）
    src/
      protocol/frames.ts         ← v1 协议帧（改编自 dsh-mizar，GPL 同源）
      host/host.ts               ← PlatformHost 接口（平台注入点）
      core/
        kernel.ts                ← 装配、连接、分派
        methods.ts               ← 方法表（27 个协议方法 + 6 个 kernel.* 扩展，共 33 个）
        session-store.ts         ← 会话持久化（JSONL + meta）
        turn-runner.ts           ← 回合运行器（Agent 主循环）
        interactions.ts          ← 审批/提问 broker（fail-closed）
        records.ts               ← 记录模型、summary/activity 投影
        stats.ts · config.ts · permissions.ts · tools.ts · delivery.ts
      engine/
        types.ts                 ← EngineAdapter 接口（引擎扩展点）
        openai-compat.ts         ← 默认引擎：OpenAI 兼容流式
    test/                        ← vitest 套件（含黄金帧契约测试）
    scripts/bundle.mjs           ← esbuild 打包 → dist + 生成 KernelBundle.swift
    dist/mizar-kernel.js         ← 打包产物（Android 宿主直接求值）
  docs/
    kernel-api.md                ← 完整外部通信 API
    kernel-architecture.md       ← 架构、复用清单、引擎适配
Swift 宿主（与内核 bundle 一起编进 MizarKit framework target）：
  MizarKit/Sources/MizarKit/Kernel/
    KernelRuntime.swift          ← JavaScriptCore 嵌入 + PlatformHost 桥
    LocalKernelTransport.swift   ← WebSocketTransport 进程内实现
    KernelBundle.swift           ← 生成的内嵌 bundle（勿手改）
测试：
  MizarKit/Tests/MizarKitTests/LocalKernelTests.swift
```

## 命令

```sh
# TypeScript 内核（在 LocalKernel/kernel/ 下）
npm install          # 首次
npm run verify       # typecheck + vitest + 打包（并重新生成 KernelBundle.swift）

# Swift 宿主与端到端测试（仓库根）
scripts/swift.sh test        # MizarKit 全量（含 LocalKernelTests，秒级）

# App 构建（内核随 MizarKit framework 编入）
scripts/ios.sh build
```

**改了 TypeScript 内核必须 `npm run build`**：`KernelBundle.swift` 是生成
文件（版本受控），App 构建不依赖 Node。

## 快速上手（GUI 视角）

```swift
let runtime = KernelRuntime(rootURL: appSupport.appendingPathComponent("LocalKernel"),
                            hostName: deviceName)
try await runtime.boot()
let connection = MizarConnection(
    configuration: .init(authority: "local", token: ""),
    makeTransport: { LocalKernelTransport(runtime: runtime) })
_ = try await connection.connect()          // 与远程主机相同的握手
// 之后 session.create / session.prompt / session.messages / approval.answer …
// ——与桌面端宿主完全相同的方法面，见 docs/kernel-api.md
```

## 许可

GPL-3.0-only（与仓库一致）。`protocol/frames.ts` 与若干投影逻辑改编自
`dsh-mizar`（GPL-3.0-only），来源与改动在文件头注明。
