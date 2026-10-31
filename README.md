# DSH-Mizar 手机端

用手机看 DSH Agent 干活，也能给它发消息、回答审批。iPhone 和 iPad 都能装。

这个仓库是 **iOS / iPadOS App**。另外两个仓库：

| | |
|---|---|
| **DSH-Mizar** | 电脑侧插件（先装它，App 才有东西可连） |
| **DSH-Mizar-Relay** | 中继服务器，让手机从任何网络连上你的电脑 |

## 一、编译运行

需要 Xcode 26 以上（iOS 26 起：界面用的是 Liquid Glass）。

```sh
git clone git@github.com:ShirazuNagisa/DSH-Mizar-iOS.git
cd DSH-Mizar-iOS

scripts/ios.sh run            # 编译并装进模拟器
```

**装到真机**：用 Xcode 打开 `DSH-Mizar.xcodeproj`，在 Signing & Capabilities 里选自己的
开发者账号，然后选你的设备运行。想用推送的话，App ID 要打开 **Push Notifications**
能力（见 `docs/testflight.md`）。

## 二、配对

1. 电脑上装好插件并重启 DSH，点侧边栏的 **DSH-Mizar**
2. 面板里会出现二维码
3. 手机打开 App，扫码

**没有别的步骤。** 不用填 token，不用填地址，不用改文件。第一次打开会依次问通知权限和
本地网络权限（两个系统弹窗，不会同时出现）；**相机权限只在点「扫码」的那一刻才问** ——
一个大部分会话都用不上的权限，在启动时问就是在教人闭着眼睛点「不允许」。

## 三、手机上能做什么

- 看会话列表和对话正文：侧边栏按工作区分组，默认收起，点开就是里面的会话；会话页里侧滑或点左上角就能把它拉出来
- 发消息，打断正在跑的 turn
- **引导发送（可选）**：设置 → 发送 → 默认引导发送，默认关闭。关闭时，在回合进行中发出的文本不会直接交给电脑排队，而是停在输入框上方一条略窄于输入框的液态玻璃长条里，本轮结束后自动发出；长条右侧三个键分别是「立即作为引导发送」（不打断模型正在进行的输出）、「退回输入框」和「删除」，左侧只显示一行待发送文本，超出部分省略。打开后，同样的消息会立刻作为引导插入正在进行的回合。
- 回答审批和提问
- **交付文件预览**：Markdown、PDF、Word，以及 PNG/JPG 与常见源代码（C/C++/Java/Python/Swift/Kotlin/HTML/CSS/JS/TS/JSON/XML 等）。源码只读、可选中，最多显示前 1 MB；图片按 40 MP / 2048 px 预算解码。预览仍由付费账户或局域网链路解锁。
- 看用量、缓存命中、上下文占用
- 切换模型、思考强度、权限
- **局域网优先（可选）**：设置 → 传输 → 局域网优先，默认关闭。打开后手动刷新或切回 App 时先扫一次局域网，手机和电脑能直连就走局域网；关闭时跳过扫描以加快重连。局域网通信时自动轮询 3 秒一次，免费账户也解锁附件和全量细节
- **归档会话**：侧边栏长按会话，可以复制会话 ID 或把它归档（从手机列表里移除，电脑上仍可找回）。归档是电脑端插件 0.8.5+ 的方法；正在跑着的会话不会被静默打断——电脑会拒绝，App 把原因显示在列表上方
- **派生（分支）会话**：电脑端用一轮结束后的「在新对话中分支」创建出来的新会话，会像普通会话一样出现在列表里，点进去有分支前的历史，也能继续对话
- **历史存在手机上**：断网也能翻会话、标题、模型和上下文用量

### 本地 Agent（实验性）

没有电脑的时候，手机自己当宿主：内核是同一份 TypeScript（`LocalKernel/`），跑在
JavaScriptCore 里，说的是与桌面端**逐字节相同**的 Mizar 协议 v1，所以会话、审批、轮次
这些界面一行没改。

- **入口**：左上角点开的那一页现在叫「Agent 选择」，第一行是「本地 Agent（实验性）」，
  下面两枚胶囊：「本地」（灰色，说明它就在这台手机上）和「尚未配置模型」（红色，没有
  配置过任何模型提供商时出现）。点它直接进入本地模式，侧边栏标题显示「本地 Agent」。
- **配置模型**：设置 → 本地 Agent（实验性）→ 模型配置 →「配置新的模型提供商」。手动填
  API 地址和 API Key，点「测试连通性」会请求 `GET <地址>/models`：连通就把返回的模型
  全部列出来供选择默认模型；401/403 说 Key 不对，404/405 说地址不对，超时说连不上。
  拉不到模型列表时也可以手动填模型 ID。Key 存在这台手机的钥匙串里，模型配置存在
  内核目录的 `config.json`。
- **这一版只在应用位于前台时工作。** 离开应用或锁屏后本地 Agent 会停止：iOS 会挂起
  整个进程，跑在进程里的内核随之冻结，没人能改这一点，所以除了设置页的说明，第一次
  进入本地模式还会弹一次提醒。被系统杀掉之后重新进入，上次未跑完的回合会被内核记成
  「已停止」，历史仍然在。
- **本地模式不支持的**（界面直接隐藏，而不是给一个点了会失败的按钮）：附件上传、交付
  文件预览、分支会话、子代理、实时活动、DeepSeek 余额。它不经过中继，所以「附件/全量
  细节」那套付费门槛对它不适用——但附件本身就是内核还没实现的能力。
- **工作区就是文件夹**：根目录在 `Documents/LocalAgent/`，隔一个文件夹就是一个工作区，
  在「文件」App 里能看到（我的 iPhone → DSH-Mizar → LocalAgent）。第一次使用会有一个
  「默认工作区」；侧栏的「新建工作区」在本地模式下问的是**名字**，DSH-Mizar 在根目录里
  建一个同名文件夹。Agent 写出的文件直接落在对应的工作区文件夹里，可以用文件 App 打开或拷走。
- **数据在哪**：工作区在 `Documents/LocalAgent/`；内核自己的会话与模型配置在
  `Documents/LocalAgent/.mizar/`（不是工作区，文件 App 里通常不显示点开头目录）。
  设置里的「清除本地会话」只删会话，**工作区文件夹和模型配置都保留**。
- **已知限制**：从没配对过任何电脑时，应用停在扫码页，而「Agent 选择」是从主界面左上角
  打开的——所以全新安装必须先配对一台电脑才能进本地模式。要不要在扫码页也开一个入口，
  还没定。

### 每一轮只显示总结

主机只发总结：每轮结尾是「**已完成，用时 xx 分 xx 秒**」，正在跑的那一轮是
「**深度求索中，用时 xx 分 xx 秒**」。两行都**不能展开** —— 逐步叙述、工具调用这些
过程文本根本不会传到手机上（省带宽，服务器那头的流量主要就是这块）。

**新到达的那条总结会像桌面端一样逐字打出来。** 速度接近模型快速输出的节奏，句子结尾
和换行处多停一拍；渲染的是解析后的 Markdown，标题、列表、代码块、表格边出现边成型。
只对「正在看的会话里新到达」的回答生效：打开历史会话、往上翻、下拉刷新带出的旧内容一律
直接显示，不会重播；打开「减弱动态效果」后也直接完整显示。这是手机端对到达回答的回放，
不是真的 token 流，所以回答本身要等下一次轮询到达才开始打。

还有第三种结尾：「**已结束**」。一轮结束需要主机写下 `turn/end`，而增量刷新是按页取
的——页的边界可能正好落在一轮的最后一条记录和它的 `turn/end` 之间；一次刷新之间攒下
的活动超过一页时，那条结束记录也可能被跳过去。Agent 不会在上一轮结束前开始下一轮，所
以「后面几轮都完成了，前面一轮还在深度求索」通常是手机缺了一条记录，不是真的在跑。App 会
先从主机回补缺失的记录；补不回来时就把那一轮记为「已结束」——它确实结束了，只是怎么
结束的没有记录，既不能说「已完成」也不能一直转下去。

### 读不到的东西不会被抹掉

标题、模型、上下文用量来自主机各自的 projection，「这次答得比上次少」是正常回答而不是
失败；读失败也不会把屏幕上已经画出来的东西清掉 —— 那正是「刚点进去，标题和用量全部
消失」的原因。整页读失败时保留上次的内容，并在会话右上角给一个刷新按钮。

### 实时活动：锁屏上会一直更新，结束会自己收起，但不会自己出现

会话在跑的时候，锁屏和灵动岛会显示一行正在跑的 turn，右边的时钟是系统的计时文本，不靠
App 每秒去刷新。App 退到后台的那一刻，它还会自己再刷新一次（重新读会话列表和正在跑的那
一轮），之后系统偶尔也会把它叫醒来做同样的事。

**会话结束时卡片会收起来，不会一直挂着。** App 醒着（或者后台刷新看到了结束）时由 App
自己收起；App 在口袋里没醒的时候，手机会把这张卡片的推送令牌交给主机，电脑那边用服务端
推送把它结束掉 —— 所以锁屏上的时钟不会为一段早就结束的会话继续走。

**但 App 一次都没打开过的时候，这个活动不会自己出现。** iOS 只允许 App 在前台时新建
活动，后台能做的只有更新或结束一个已经存在的活动。要让它自己出现，需要主机通过服务端推送
「启动活动」（push-to-start，那是另一个推送令牌），这个版本还没有 —— 所以新开的会话要等
你打开一次 App 才会锁屏。

### 界面

- **侧边栏**（在会话页往右滑，或点左上角）：顶部固定着电脑的名字、刷新和搜索框，列表从它们下面滑过。名字下面一行是 Agent 胶囊和连接状态条：两台或三台设备的图标，中间用一排点连起来，断在哪一段就在哪一段打叉；只有一个 Agent 时胶囊仍然显示名字，但点不开。电脑的名字本身是按钮，点开是切换电脑、添加电脑的小窗。下面按工作区分组，正在打开的会话所在的工作区会自己展开；正在跑的会话前面是一颗「双星」（Mizar 本来就是一对双星），等你审批的会话后面有一只橙色的手。最下面是连接胶囊和设置；连接胶囊的第二行就是当前链路：局域网通信时写「局域网通信」，走中继时写「经由中继」。会话行可以长按，菜单里是「复制会话 ID」和「归档该会话」。
- **轮次索引**（在会话页往左滑，或点标题）：侧边栏的镜像，从右边出来，一轮一行，像桌面端 Agent 的轮次列表。屏幕上正在显示的那几轮在时间线上被点亮；每行下面一条细线，长短就是这一轮花的时间；可以只看未完成的。点一行就跳到那一轮，它会亮一下。iPad 上它是右边单独的一栏，收起时变成会话右侧的一排刻度，按住上下滑动可以快速定位。
- **右侧抽屉的三段开关**：「轮次」「子代理」「预览」。轮次与子代理两段后面都带当前会话的个数；子代理页列出这个会话委派出去的子代理（分支出来的会话不算），预览页显示模型交付的文件。
- **连接小窗**（点底部的连接胶囊）：连接方式和地址、连上多久、实时测出来的延迟曲线，以及自动轮询在做什么——跟随运行中一轮的 10 秒轮询（局域网通信时 3 秒，带倒计时）、电脑推送的实时更新、45 秒一次的兜底检查。只在小窗打开时才测延迟。
- **所有弹出的东西都是从按钮里长出来的小窗**，不是占满屏幕的大窗口：模型、上下文、命令、权限、新建会话、刷新进度、设置、切换电脑、配对（摄像头也在小窗里打开）、给电脑起名。唯一的例外是系统自己的分享面板。
- **会话页**：你的话是右边的青色气泡，Agent 的回答是整页正文，不套气泡，新到达的回答会逐字打在页面上；审批和提问停靠在输入框上方，一次一张，「下一个」翻下一张；打字时它们收成一颗小药丸。
- **没打开会话时**：直接打字、选工作区、发送，就会新建会话并把这句话当第一条发过去。
- **触感**：设置里一个开关管所有震动。打开「减弱动态效果」后，所有动画都改成原地淡入淡出，状态照样变化，只是不再移动。

### 局域网优先

中继是「不在同一个网络也能连」的兜底，不是首选。App 会不会在重连时找局域网，由 **设置 →
传输 → 局域网优先** 决定（默认**关闭**）：

- **关闭（默认）**：直接跳过扫描，重连走已保存的通道 —— 最快，适合手机在蜂窝网络、或保存
  的局域网地址早已过期的情况（不会为一次注定失败的探测多等两秒半）。
- **打开**：在两种用户能感知的重连时机重新问一次「电脑是不是就在这个局域网里」：
  **手动刷新**（侧边栏下拉、右上角刷新、连接小窗里的重新连接），以及 **从后台回到 App**；
  局域网 socket 掉线后的自动切换也会先扫一次再回退中继。扫到就切直连，扫不到照旧回退。

打开后扫描优先用配对时记下的直连地址；如果连着中继，还会向电脑要一份它当前监听的所有地址（电脑端插件 0.8.5+ 的 `host.info.addresses`，旧插件没有这个字段，就只试配对地址）。每个地址都用配对时同一个免鉴权 `hello` 探一次，**主机 id 对得上**才切过去 —— 局域网上碰巧有别的 DSH 服务端时不会被当成你的电脑。切过去之后这个地址会写回配对，下次启动直接用。

**电脑端得先监听局域网地址。** 插件 0.8.5 起，开着中继也默认同时监听局域网（127.0.0.1 仍保留给中继回放），新配对的二维码同时带直连和中继；老配对不用重扫，扫描时会通过 `host.info` 拿到当前地址。但如果 profile 里显式写过 `bind.mode: loopback` 或 `relay.preferLoopback: true`，它们仍然优先，只监听本机——那就永远不会有局域网通信（其余功能照常走中继）。去掉这两项、重启 DSH 即可。

**局域网断了会立刻切中继。** 局域网 socket 一断，App 不等下一次刷新/轮询，马上重连（局域网优先打开时先扫一次局域网，扫不到再按「中继优先、原局域网地址兜底」重连）；重连本身也总是把配对里**所有**路由排在当前路由后面，一条拨不通就当场换下一条，不会反复对已经失联的地址重连。切换成功后侧边栏从「局域网通信」变回「经由中继」，会话列表、审批和实时活动一起刷新。离开 Wi-Fi 再回来、或电脑重新上线后，如果局域网优先是打开的，手动刷新/回到前台会再扫描局域网并切回直连；关闭时保持当前通道，需要直连就先去设置里打开它。

**电脑端插件建议 0.8.7+。** 0.8.5 及更早有一个只在换网络后暴露的问题：中继隧道变成半开（socket 还在、但中继已经不再响应），插件不会自己发现，手机会直连/中继都连不上，只能重启 DSH。0.8.6 给隧道加了 120 秒静默看门狗并引入单监听；0.8.7 补上了注册表在插件模块被多次加载时不共享的问题，保证一个 DSH 进程只剩一个监听（不再出现 19390…19397 多代端口并存，配对里的直连地址也就不会过期）。

局域网通信时的不同：

- 侧边栏底部写「局域网通信」，连接小窗里写「局域网通信中」，不显示中继域名/服务器档位；
- 运行中一轮的自动轮询从 10 秒提到 **3 秒**；
- **附件上传和「全量细节」不再要求付费账户** —— 这两样是付费计划里唯一花中继带宽的东西，局域网通信不经过中继，也就不应该收费。付费账户的其余部分（高带宽中继）照旧。

日志导出里会记 `LAN scan:` 开头的行，能看出扫了哪些地址、为什么没切；关闭局域网优先时是
`LAN scan: skipped (local network priority is off)`。开关打开/关闭也会记一行
`local network first on/off`。

### 连不上时它怎么显示

侧边栏顶部、Agent 胶囊右边是一条连接状态条：手机和电脑用一排点连起来，走中继时中间多一台
服务器（手机、中继、电脑）。连不上时，断在哪一段，就在那一段的中间点上一个红叉：

- **中继左段打叉** —— 手机到不了中继：没有网络、DNS 失败、超时、连接被拒、5xx。
- **中继右段打叉** —— 中继答上了，但它那边没有你的电脑（电脑上的 DSH 没开、隧道掉了）。
  中继对「这个房间没有隧道」回的是 `404`，App 读的是这个状态码，不是错误文字。
- **直连时正中间打叉** —— 局域网、tailnet、P2P 都没有中间那一跳，线断在哪里就是哪里。
- **电脑左侧打叉** —— 两段都通，是电脑自己拒绝了这台手机（鉴权失败、设备被撤销）。

连上时没有叉，线上的点从左到右轮流胀大缩小，像一波流过去，表示这条链路正在通信；正在连接时
点是灰的、不呼吸。两条路由都失败时，叉画在**说得最清楚**的那一条上，而不是最后到的那条：中继的 `404`
比局域网地址超时更能说明问题，所以即使局域网那条六秒后才超时，画面上仍是中继那一段的叉。

这一条只回答「手机和电脑之间通不通」。请求本身的失败（归档被拒、切模型失败、读取失败）
不在这里显示，只进日志。VoiceOver 读的是一句短状态（「连接正常，经由中继服务器」
「已连接服务器，但未能连接到电脑」）。

## 四、开发

```sh
scripts/swift.sh test         # MizarKit（协议层）全部测试，跑在 Mac 上，几秒
scripts/ios.sh build          # 编译 App
```

图标与星标动画（两种动效、参数、灵动岛素材怎么来）见 [`docs/app-icon.md`](docs/app-icon.md)。
图标源在桌面端仓库与 `icon-design/`，这里的两个脚本只负责把它变成 iOS 的样子：

```sh
python3 scripts/make-app-icon.py        # AppIcon-1024.png ← AGI Mizar 的图标
python3 scripts/make-star-geometry.py   # 星形路径 + 灵动岛图标 + 动作胶片
```

截图用 `ScreenshotTour`（同样需要假主机）：

```sh
TEST_RUNNER_MIZAR_SHOTS=/tmp/tour scripts/ios.sh test "iPhone 18 Pro" -only-testing:DSH-MizarUITests/ScreenshotTour
```

UI 测试需要一个假主机（不需要真的 DSH）。它用 `ws` 起 WebSocket 服务端，所以**先装一次依赖**：

```sh
npm install                   # 只装 ws，给假主机用；App 本身没有依赖
```

`test` / `test-fast` 会**自动在 19395、19396 端口起假主机**，退出时自动关掉；不需要再手动
`node scripts/mock-host.mjs ... &`。如果已经手动起了假主机，脚本会直接复用，不会误杀。
要自己管理假主机时加 `MIZAR_NO_MOCK=1`。

**日常迭代用 `test-fast`**：先 `build-for-testing`，再 `test-without-building`，默认不收集
失败诊断（`-collect-test-diagnostics never`）。不传 `-only-testing` 时默认跑 AccountUITests
（账户/设置/订阅，约 5 分钟）；加过滤只跑相关测试：

```sh
# 默认：账户/设置/订阅整组
scripts/ios.sh test-fast "iPhone 18 Pro"

# 某个具体测试，通常几十秒
scripts/ios.sh test-fast "iPhone 18 Pro" -only-testing:DSH-MizarUITests/AccountUITests/testSignedOutSettingsShowsBlankAccountRow

# 设置相关的一小组 AppFlow 测试
scripts/ios.sh test-fast "iPhone 18 Pro" \
  -only-testing:DSH-MizarUITests/AppFlowTests/testTheSidebarOpensSettings \
  -only-testing:DSH-MizarUITests/AppFlowTests/testTheSettingsScreenFollowsTheLanguage
```

**发布前才跑完整套件**：

```sh
scripts/ios.sh test "iPhone 18 Pro"   # 56 个 AppFlow + 5 个 0.9.4 功能 + 2 个实时活动 + 9 个 Account（共 72 个），约 20–25 分钟
```

CI 里如果需要失败诊断，覆盖环境变量：

```sh
MIZAR_TEST_DIAGNOSTICS=on-failure scripts/ios.sh test "iPhone 18 Pro"
```

**不要同时起两个 `xcodebuild test`**，会互相抢模拟器，结果是两边都不可信。

**为什么完整套件慢**：每个 UI 测试都重新启动 App、重新配对 mock host；命名弹窗默认只等 3 秒，
但每个断言仍有 20 秒容错，失败时 Xcode 的 `simctl diagnose` 可能再跑 10 分钟。日常只跑
`swift.sh test` + 相关 `test-fast`，完整套件留给提交/发布前。

假主机同时提供 `/account/v1`（注册、登录、`/me`、邀请码 `MOCK-INVITE`、App Store 交易与同步），
以及 `session.activity`（一轮运行中的完整细节；每次轮询多返回一行，用来观察瀑布式插入），
账户 UI 测试用 `-mizarAccountURL http://127.0.0.1:19395` 把它指过去；每次启动的
`-mizarAccountFreshStart` 保证测试从「未登录」开始。

订阅的 Apple 付款面板在模拟器 UI 测试里没法真出现，所以 Debug 构建有一个只在测试里用的
假商品：`-mizarMockSubscription`（价格默认 `¥6.00`，可用 `-mizarMockSubscriptionPrice` 改）。
真实 StoreKit 链路在模拟器上手动验证：Xcode 打开工程 → Edit Scheme → Run → Options →
**StoreKit Configuration** 选 `DSH-Mizar.storekit`，商品 id 是
`me.shirazu.dshmizar.paid.monthly`（¥6/月，见 `docs/testflight.md`）。

`scripts/swift.sh test` 覆盖账户模型、账户客户端、Keychain 之外的存储、Relay 身份头、
分块上传、`session.activity` 的线上形状与请求形状、打字机的节奏与逐字裁剪，以及中英文
`.strings` 的 key 对齐，共 474 个测试。

**打字机效果的调试开关**：Debug 构建启动参数加 `-mizarTypewriterDemo`，打开会话时会把
最新一条模型总结完整演示一遍（Release 构建里没有这个开关）。

## 五、打包

```sh
scripts/release.sh export     # → ../../release/iOS/DSH-Mizar-<版本>.ipa
scripts/release.sh upload     # 直接传到 App Store Connect（TestFlight）
```

签名需要一个付费的 Apple 开发者账号（`MIZAR_TEAM_ID` 可覆盖 team id）。
上传的细节和第一次上传要准备的东西见 `docs/testflight.md`。

## 目录

| | |
|---|---|
| `DSH-Mizar/` | App 本体：视图、AppModel、权限、推送 |
| `MizarKit/` | 协议层（连接、帧、会话模型、缓存），`swift test` 跑的就是它 |
| `DSH-Mizar-LiveActivity/` | Widget Extension：实时活动的灵动岛和锁定屏幕。图片只在它自己的资源目录里找得到 |
| `DSH-MizarUITests/` | XCUITest，对着 `scripts/mock-host.mjs` 跑 |
| `DSH-Mizar.storekit` | StoreKit 模拟器配置（订阅商品与价格），手动验证购买流程用 |
| `protocol/fixtures/` | 从真主机录下来的帧（golden frames），两个语言共用 |
| `scripts/` | 编译、测试、假主机、打包 |
| `archive/` | 0.7.2 之前「全量传输」的渲染实现，不编译，留着备用 |

协议本身在插件仓库：`docs/protocol-v1.md`。

## 许可

本项目以 **GNU General Public License v3.0**（GPLv3，SPDX：`GPL-3.0-only`）发布。
许可证全文见 [LICENSE](LICENSE)。

另附一条 **App Store 额外许可**（GPLv3 第 7 条）：允许通过 Apple App Store /
TestFlight 分发本程序及其衍生作品，以化解 GPLv3 与商店条款、DRM 以及第 6 条
「安装信息」要求之间的冲突；源码仍须按 GPLv3 提供。全文见
[LICENSE-EXCEPTION](LICENSE-EXCEPTION)。

### 运行中一轮的完整细节（付费账户，或局域网通信）

付费账户（以及局域网通信中的任何账户）在看一轮正在跑的对话时，状态行（「深度求索中，用时 …」）右边会多一个 `>`：点开，
状态行**下面**展开一块约 200 pt 高的详情区，按顺序滚动显示这一轮正在做什么——思考、运行的
命令、命令输出、工具调用，一行一条（图标 + 中文类别 + 一行截断文本）。新行会像瀑布一样从状态
行下方依次落下；再点一次收起，整块向上收回。状态行本身不动、不消失。

- 详情区是**内部滚动**的，不会把整轮过程一次性摊开把对话挤走；上下边缘是渐隐的。窗口高度在
  展开那一刻就固定，新来的行只会增加内层滚动内容，不会再让外层会话跟着上下跳。
- **只播最新一段**：打开（或折叠后再打开）时只给最近约 10 行做瀑布入场，已经加载的历史
  直接显示——以前每次展开都把整段重新刷一遍，一轮很长时能刷好几秒。
- **上翻懒加载**：把详情区滑到顶，会按页向电脑要更早的细节（一次一页，最多 100 行），翻页
  后当前阅读位置保持不动；到本轮开头或累积到 1500 行就停止。新行只有在本来就停在底部时
  才自动跟随，往上翻的人不会被拽回底部。
- 详情行只是信息，不能点、不能展开——完整的进程负载不会传到手机上。
- 未解锁时（既没付费、也不是局域网通信）**完全保持原样**：没有 `>`，也**不会**向电脑请求
  `session.activity`（不是隐藏，是根本不发请求）。付费账户和局域网通信自动拉取，没有开关。
- 这是一路约 1 秒一次的轮询，只取最近 60 行，只在这一轮运行期间；这一轮结束或页面离开就
  停止并清空。单次读取失败不会清掉已经显示的内容。
- 需要电脑端插件支持新的 `session.activity` 方法（0.9.0+）；历史懒加载需要 0.8.5+。老插件
  返回「未实现」时界面就只是没有 `>`，不会报错；不支持分页的老插件下详情区只显示最近一段，
  上滑不会转圈。

### 账户、订阅与附件

- **账户是可选的**。不登录时所有免费功能照常：配对、会话、对话、审批、实时活动、推送。启动不会弹登录框，账户只在「设置」里出现。
- **设置 → 账户**：未登录时是一张空头像、未登录、免费账户；登录后是头像、用户名、免费账户 / 付费账户。点进去可以注册、登录、用 Apple 登录、看本账户登录的设备、退出登录、删除账户。
- **头像**：Apple 登录不会返回 Apple ID 的照片（Apple 没有公开这个 API），所以 Apple 账户默认显示 Apple 风格的首字母头像。账户页点头像（相机角标）可以从相册选一张，选完后账户页、设置页、侧边栏都会显示它；目前保存在本机，不跨设备同步。
- **付费账户**有两种来源：App Store 自动续期订阅（¥6/月，在 App Store Connect 里定价）和邀请码 / 管理员授予，付费状态取两者到期时间的较大值。订阅按钮会真的调起 Apple 的付款面板，价格显示的是 `product.displayPrice`（不写死 ¥6）；可以恢复购买、跳转管理订阅。自动续期条款和隐私 / 使用条款链接都在订阅区。
- **邀请码**：账户页 → 兑换邀请码。邀请时长会在现有到期时间上叠加。
- **附件对付费账户开放；局域网通信时对任何账户开放**（不经过中继，不花服务器带宽）。输入框左边的「+」打开命令面板，最上面并排两个按钮：添加照片、添加文件。既没付费、也不是局域网通信时按钮带锁并写着「付费账户专享」，点一下会打开账户页，而不是什么都不发生。
- 照片走 `PhotosPicker`：只读取你选中的照片，**不需要相册权限**，Info.plist 里也**没有** `NSPhotoLibraryUsageDescription`——这不是漏了，是刻意不申请。文件走系统文件选择器。
- 照片会先缩放（长边 ≤ 2048）并重新编码成 JPEG；限制是单张图片 ≤ 10 MiB、单个文件 ≤ 32 MiB、一次最多 8 个附件（其中最多 4 张图片）、合计 ≤ 64 MiB。超限会在本机就告诉你是哪一条，不会先上传再被拒绝。
- 附件通过已连上的 Mizar WebSocket 分块上传（128 KiB 一块），发送时用 `attachmentIds` 引用；上传进度显示在缩略图下方。发送失败会把文字和附件放回输入框，不会静默丢内容。如果电脑上的 DSH 插件太旧、不认识上传方法，会明确提示去电脑上更新 DSH。
- 账户服务器只是主力的 `/account/v1`。**它连不上时免费功能不受影响**：账户页保留缓存的资料并说明连不上，不会把已登录的人显示成未登录。

## Privacy

DSH-Mizar collects the minimum needed for an optional account:

- **Account**: the email address, username and password hash (or the Sign in with Apple subject), stored on the account server at `dshmizar-1.shirazu-nagisa.com`. The password is never sent anywhere else, and is stored only as a scrypt hash.
- **Avatar**: the email's MD5 hash may be sent to a Gravatar mirror to fetch a public avatar; the app falls back to generated initials.
- **Devices**: the install id, device name/model and app version, so the account's device list can be shown and email accounts can be limited to two devices.
- **Subscription**: the App Store transaction is verified by the relay to set the paid expiry; the app never sees a payment method and never stores a receipt.
- **Traffic**: the relay counts bytes per account-token hash, per install, or per anonymous hash of room/user-agent for 90 days. It is used for quotas and the admin traffic table, not for profiling.
- **Attachments and conversations never go to the account server.** They travel between the phone and the operator's computer over the paired connection; the relay forwards them as WebSocket frames and does not store them.
- Signing out deletes the token from the phone's Keychain; deleting the account removes the server-side record. There is no analytics SDK, no advertising SDK and no third-party tracking in the app.

The App Store listing uses https://dsh-mizar.shirazu-nagisa.com/privacy/ as its privacy-policy URL.
