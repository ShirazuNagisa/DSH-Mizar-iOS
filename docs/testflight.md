# 发布到 TestFlight — 网页操作全流程

产物已经就绪（`scripts/release.sh archive|export` 都成功过），剩下一半只能在网页上做。

## 先抄这些值

下面每一步要填的东西都在这里，**从这张表复制，不要凭记忆**：

| 字段 | 值 |
|---|---|
| **Bundle ID** | `me.shirazu.dshmizar` |
| **显示名** | `DSH-Mizar` |
| **版本号** | `0.9.9` |
| **构建号** | `37` |
| **Team ID** | `5Q2A46685M` |
| 团队名 | Vreeland Lee |
| 签名身份 | `Apple Distribution: Vreeland Lee (5Q2A46685M)` |
| 建议 SKU | `dshmizar001` |
| 主要语言 | Chinese (Simplified) 或 English |
| 支持设备 | iPhone + iPad |
| 本地化 | `en`、`zh-Hans` |
| 出口合规 | 已在 Info.plist 声明豁免 |

---

## 第 1 步：确认 App ID 已注册

**打开**：https://developer.apple.com/account/resources/identifiers/list

在列表里找 **`me.shirazu.dshmizar`**。

- **有** → 跳到第 2 步
- **没有** → 点右上角 **`+`**
  1. 选 **App IDs** → **Continue**
  2. 类型选 **App** → **Continue**
  3. **Description**：`DSH-Mizar`
  4. **Bundle ID**：选 **Explicit**，填 `me.shirazu.dshmizar`
  5. **Capabilities**：勾上 **Push Notifications**
     （通知要用它。不勾的话真机上 `registerForRemoteNotifications()` 会静默失败：
     权限弹窗问了、用户点了允许、然后什么都不会到 —— 这是最难查的一种坏法。
     其余 iCloud、App Groups 都不用勾）
  6. **Continue** → **Register**

> ⚠️ `me.shirazu.dshmizar` **必须和 Xcode 工程里完全一致**，包括大小写。
> 拼错了后面第 2 步的下拉框里就找不到它。

---

## 第 2 步：创建 App 记录

**这一步 Xcode 替你做不了**，只能在网页上做，而且**一个 Bundle ID 只做一次**。
我第一次试上传时它就停在这里，报 `Downloading App Information`。

产物都在 **`release/iOS/`**（工作区根目录，非隐藏）：

```
release/iOS/
└─ DSH-Mizar-0.9.9.ipa         ← 由 scripts/release.sh export 生成，可用 Transporter 上传

iOS/.devcache/DSH-Mizar.xcarchive   ← 本次 archive，双击打开 Organizer 用它上传
docs/ios/ios-release-notes-0.9.9.md     ← 这一版改了什么、怎么验（工作区 docs/）
```

> **`.ipa` 为什么可能不在。** 导出 `.ipa` 要用 App Store 描述文件，而描述文件必须带上
> Sign in with Apple 能力；本机缓存的那份 Store 描述文件是 10 月 6 日生成的，早于该能力
> 被打开。xcodebuild 自己换不了 —— 它需要 Xcode 里登录的 Apple ID（终端里跑会报
> `exportArchive No Accounts`）。所以：要么在**自己的终端**里跑
> `scripts/release.sh export`，要么直接用上面的 `.xcarchive` 走 Organizer —— 后者会用你
> 已登录的账号重新生成描述文件，一步到位。

---

**打开**：https://appstoreconnect.apple.com/apps

1. 点左上角的 **`+`** → **New App**
2. 弹窗里填：

| 字段 | 填什么 |
|---|---|
| **Platforms** | 勾 **iOS** |
| **Name** | `DSH-Mizar` |
| **Primary Language** | Chinese (Simplified) |
| **Bundle ID** | 下拉选 `me.shirazu.dshmizar` |
| **SKU** | `dshmizar001`（用户看不到，随便填，唯一即可） |
| **User Access** | Full Access |

3. 点 **Create**

> **Name 是全局唯一的。** 如果 `DSH-Mizar` 被占用了，换一个比如
> `DSH-Mizar Remote` —— **只影响 App Store 上显示的名字**，不影响 Bundle ID，
> 也不影响手机上装出来的名字（那个由 `CFBundleDisplayName` 决定，是 `DSH-Mizar`）。

> **Bundle ID 下拉里找不到它？** 说明第 1 步没做，或者拼错了。回去做第 1 步。

---

## 第 3 步：上传构建

这一步**不在网页上**，但做完之后剩下的都在网页上。

**最省事的方式**（用你 Xcode 里已登录的账号，不需要额外配任何密钥）：

```bash
open iOS/.devcache/DSH-Mizar.xcarchive
```

Xcode 的 **Organizer** 会打开：

1. 选中 **DSH-Mizar 0.9.9 (37)**
2. 点右侧 **Distribute App**
3. 选 **TestFlight & App Store** → **Distribute**
4. 后面一路默认：
   - **Upload**（不是 Export）
   - **Automatically manage signing**
   - 最后点 **Upload**
5. 等进度条走完，出现 **Upload Successful**

> 命令行也可以（`scripts/release.sh upload`），但需要一份 App Store Connect
> API 密钥。网页这边走 Organizer 更快。

---

## 第 4 步：等它处理完

回到 **https://appstoreconnect.apple.com/apps** → 点进 **DSH-Mizar** →
左侧 **TestFlight** 标签。

构建会显示 **Processing**（正在处理），通常 **5–15 分钟**。

处理完状态变成 **Ready to Submit** 或出现在构建列表里。

### 如果出现 "Missing Compliance"

正常情况下**不该出现**——我已经在 `Info.plist` 里声明了
`ITSAppUsesNonExemptEncryption = false`。

万一出现了，点那个黄色提示进去回答：

> **Does your app use encryption?**
> 选 **No**（或者选 "it uses only exempt encryption"）

这个 App 只用系统的 HTTPS/TLS，属于豁免范围。

---

## 第 5 步：加测试人员

左侧 **TestFlight** → **Internal Testing**（内部测试）

1. 点 **`+`** 建一个测试组，名字随便，比如 `Me`
2. 点 **`+`** 往组里加人：
   - **内部测试**：只能加你 App Store Connect 团队里的成员。
     一个个人开发者账号通常就是你自己，**用你的 Apple ID 邮箱**
   - **不需要 Apple 审核**，加完立刻能装 ← **自己测试走这条最快**
3. 加完在构建那一栏点 **`+`** → 选 `0.9.9 (37)` → **Add**

> **外部测试**（External Testing）可以加最多 10000 人，但**第一次需要 Apple 审核**，
> 通常 1–2 天。自己用不上走这条。

---

## 第 6 步：手机上装

1. App Store 搜 **TestFlight**，装上（Apple 官方出品，免费）
2. 打开 TestFlight，用**你接受邀请时用的那个 Apple ID** 登录
3. 会看到 **DSH-Mizar**，点 **Install**
4. 装完直接从 TestFlight 里打开

---

## 常见卡点

| 现象 | 原因 | 怎么办 |
|---|---|---|
| `Downloading App Information` 报错 | App 记录还没建 | 做第 2 步 |
| Bundle ID 下拉里没有 | App ID 没注册 / 拼写不符 | 做第 1 步 |
| Name 报"已被使用" | 名字全局唯一 | 换一个名字，Bundle ID 不变 |
| 卡在 Processing 超过 1 小时 | 偶发 | 换个构建号重新上传一次 |
| 出现 Missing Compliance | 罕见 | 按第 4 步回答 |
| 构建传上去了但 TestFlight 里没有 | 少了出口合规回答，或没加进测试组 | 检查第 4、5 步 |
| 想传第二次 | **构建号必须更大** | 见下 |

### 传第二个构建的时候

改 `iOS/DSH-Mizar.xcodeproj/project.pbxproj` 里这两个值：

- `MARKETING_VERSION` → 用户看到的版本，例如 `0.1.1`
- `CURRENT_PROJECT_VERSION` → 构建号，**必须比上一次大**（`1` → `2`）

`ExportOptions.plist` 里 `manageAppVersionAndBuildNumber` 是 **false**，
所以 Xcode 不会自作主张改构建号。这是故意的：否则上传完之后你无法回答
"这个构建到底是哪一版"。

然后重新 `scripts/release.sh archive` 再走第 3 步。

---

## 必须说清楚的一件事

**这个 App 单独装上是用不了的。**

它要连到一台跑着 DSH 的电脑，而那台电脑上要装 `dsh-mizar` 插件。测试人员必须同时有：

1. 一台电脑，装了 DSH 和本插件
2. 电脑和手机在同一个局域网，或电脑已经连上中继（见 [中继部署](relay-deployment.md)）
3. 从电脑的 DSH Web 面板扫码配对

所以 **TestFlight 的适用范围是"你自己"或"你帮忙配好电脑的人"**。作为公开上架它没有
独立价值，审核时也会被问到"用户拿到这个 App 能做什么"。

要发布给不认识的人，缺的不是 TestFlight，而是：电脑端插件的公开分发方式 + 配对引导
流程，或者一个中继服务。

---

## 账户、订阅与附件（上架前必须做的三件事）

账户是**可选功能**：不登录也能配对、看会话、发消息。但下面三件事不做，账户页和订阅按钮就是坏的。

### 1. App ID 开启「Sign in with Apple」

`DSH-Mizar.entitlements` 里已经有：

```xml
<key>com.apple.developer.applesignin</key>
<array><string>Default</string></array>
```

这只写了"要这个能力"。**还必须在这两处真的打开**，否则签名时能力被剥掉，点 Apple 登录
会立刻失败（error 1000），而且界面上只有一个不动的按钮：

1. https://developer.apple.com/account/resources/identifiers/list → `me.shirazu.dshmizar`
   → Capabilities 勾选 **Sign in with Apple** → Save
2. Xcode → DSH-Mizar target → Signing & Capabilities → **+ Capability** → Sign in with Apple
   （自动签名会重新生成带这个能力的 profile；第 1 步没做的话这里加不上）

不需要 `NSPhotoLibraryUsageDescription`：照片走 `PhotosPicker`，只拿选中的照片，不申请
相册权限。**不要**为了"看起来完整"把它加回去，那会平白多一个权限弹窗。

### 2. App Store Connect 里建订阅商品

| 项 | 值 |
|---|---|
| 类型 | 自动续期订阅（Auto-Renewable Subscription） |
| 订阅组 | `Mizar Paid` |
| Product ID | **`me.shirazu.dshmizar.paid.monthly`**（必须一字不差） |
| 价格 | ¥6.00 / 月（其他地区由 Apple 自动换算） |
| 本地化 | `en`（Mizar Paid）、`zh-Hans`（Mizar 付费版） |
| 审核截图 | 账户页订阅区那一屏 |

App 里订阅按钮的文案和价格都来自 `Product.displayPrice`，**没有写死 ¥6**；商品没建好或
还没生效时，订阅区会显示"暂时无法从 App Store 获取"，不会显示一个假价格。

`-mizarMockSubscription` 只是 Debug 构建给 UI 测试用的假商品，Release 里编译不进去。

### 3. 账户后端和中继

- 账户 API 只跑在主力1（`accounts.enabled=true`）：
  `https://dshmizar-1.shirazu-nagisa.com/account/v1`。这个地址写死在 `MizarKit` 的
  `AccountClient.productionBaseURL`，改主机要改代码。
- 中继要开 `role` + `accounts`，且 App Store 校验用到的 `bundleId` 必须是
  `me.shirazu.dshmizar`、`productId` 必须是上面的商品 id（见 `relay-deployment.md`）。
- **无法连接账户服务器时免费功能不受影响**，账户页显示缓存的资料 + 连不上。这是刻意设计，
  不要改成"连不上就退出登录"。

### 手动验证真实 StoreKit（模拟器，不需要开发者账号）

1. Xcode 打开 `DSH-Mizar.xcodeproj`
2. **Product → Scheme → Edit Scheme → Run → Options**
3. **StoreKit Configuration** 选 `DSH-Mizar.storekit`（在 `iOS/` 根目录）
4. 运行 App，登录任意账户 → 设置 → 账户 → 订阅 → 点订阅按钮
5. 会弹出一个**模拟的** Apple 付款面板（不是真扣款），确认后账户应变成「付费账户」
6. 验证恢复购买：删掉账户数据或换设备，再点「恢复购买」

`.storekit` 文件里商品是 ¥6/月、中文 storefront；如果 Xcode 打开时提示迁移格式，让它迁
并保存即可（不同 Xcode 版本 schema 有小差异，商品 id 和价格不变）。

### 隐私政策与使用条款

订阅区里有「隐私政策 / 使用条款」两个链接：

- 隐私政策 → `https://dsh-mizar.shirazu-nagisa.com/privacy/`（主力0 上的静态页面）
- 使用条款 → `https://dsh-mizar.shirazu-nagisa.com/terms/`（同上）

两个页面必须真的可访问、内容与 App 实际行为一致；App Store Connect 的「隐私政策 URL」
填上面第一个。页面内容以 `iOS/README.md` 的 Privacy 段落为准（同一条政策，两处措辞不要分叉）。
**不要**把这两个链接指到 `dshmizar-1` 账户主机 —— 那是账户 API，不是网站。

### 附件

附件对付费账户开放；**局域网通信时（直连电脑、不经过中继）对任何账户开放**，因为这部分
带宽不由中继承担。需要在电脑端插件 0.8.4+（`upload.*`；0.9.4 起局域网解锁也是这个版本
起就有）。旧插件在发送附件时会明确提示「这台电脑上的 DSH 插件版本过旧，无法接收附件」，
而不是发送失败。上限：图片 ≤ 10 MiB、文件 ≤ 32 MiB、一次 ≤ 8 个（图片 ≤ 4）、合计
≤ 64 MiB；照片会先缩到长边 2048 再压缩，正常手机照片远低于限制。

### 传输设置（0.9.4 测试要点）

- 设置 → **传输** → **局域网优先**，默认关闭。关闭时刷新/重连不扫描局域网（日志是
  `LAN scan: skipped`），打开后手动刷新/回前台/重新连接/局域网断线自动切换会先扫描再回退。
- 这是 0.9.4 的行为变化：以前每次刷新都会扫描，现在需要时自己去设置打开。
- UI 回归测试 `DSH-MizarUITests/LanPriorityUITests` 覆盖默认关闭不探测、打开后探测、重启保持。

### 电脑端插件版本（0.9.4 相关）

| 功能 | 最低插件版本 |
|---|---|
| 附件上传、运行中轮次完整细节 | 0.8.4（附件）/ 0.9.0（`session.activity`） |
| 局域网扫描时向电脑要当前监听地址（`host.info.addresses`） | 0.8.5 |
| 侧边栏「归档该会话」（`session.archive`，并在列表里过滤已归档会话） | 0.8.5 |
| 运行中全量细节上翻懒加载（`session.activity` 的 `beforeSeq`/`turn`/`oldestSeq`） | 0.8.5 |
| 中继隧道静默断线自愈、一个进程只保留一个监听（端口不漂移） | 0.8.7（推荐） |

插件没更新时，旧插件会回「未实现」：归档菜单会显示失败原因；局域网扫描退回只试配对时
记下的地址，其余功能不受影响。

**建议把电脑端插件更新到 0.8.7。** 0.8.5 及更早没有中继隧道自愈：电脑换网络后隧道可能
静默半开（本机 socket 还在、中继已把房间摘掉），手机上直连和中继都连不上，只能重启 DSH
才能恢复；另外 0.8.5 及更早重复挂载插件时可能多绑端口（19390/19391/19392），让配对里保存
的直连地址过期。0.8.7 的日志会出现 `relay: …redialling…` 并在两分钟内自行恢复；它同时保证一个 DSH 进程只剩一个 Mizar 监听。

另外，**0.8.5 起插件默认在中继开着时也监听局域网地址**（旧的「有中继就只听 127.0.0.1」
默认已经改掉），否则 App 没有直连地址可扫、局域网通信永远不会发生。如果某台机器的 profile
里显式写过 `bind.mode: loopback` 或 `relay.preferLoopback: true`，它们仍然优先：删掉这两项
（或改为 `mode: lan` / `preferLoopback: false`）再重启 DSH 才能局域网直连。127.0.0.1 会
一直保留，中继请求是从本机回放到那个端口上的。
