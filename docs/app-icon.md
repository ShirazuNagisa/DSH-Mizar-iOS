# 应用图标与环形标记

手机和电脑是一个产品，用同一份图标母版：五段圆头弧线组成的一只环，长弧在右，三段短弧在左，
十点钟方向有一颗圆点。iOS 的 `AppIcon` 是两个 1024 PNG（浅色 / 深色），Live Activity 是同一只环
裁出来的白色模板；应用里的标记不是位图，而是一条由同一组数字画出来的 `Canvas`，所以图标和标记
不会因为各自重画而漂移。

```
python3 scripts/make-app-icon.py          # AppIcon 1024 两个外观 + 灵动岛模板
python3 scripts/make-app-icon.py --check  # 只检查提交的 PNG 是否过期
```

母版在工作区根的 `icon-design/masters/mizar-icon/`：

| 文件 | 用途 |
|---|---|
| `light.png` / `dark.png` | 不透明满幅图标；iOS 直接用它生成 AppIcon |
| `light-transparent.png` / `dark-transparent.png` | 透明字重；只作为没有共享几何模块时的栅格回退 |
| `ring_geometry.py` | 五段弧的几何与栅格化；桌面 `.icns` / `.ico`、iOS 灵动岛模板、Android 通知图标都从这里取 |
| `README.md` | 母版来源、尺寸与重建方式 |

## 1. 图标本体

| 平台 | 形状 | 为什么 |
|---|---|---|
| macOS（桌面端） | 1024 画布 + 824 圆角方块 + 透明外边距 | Dock / Finder / 启动台要这个网格；`AGI Mizar/scripts/make-icons.py` 负责 |
| iOS（本仓库） | 1024 **满幅、不透明、无圆角**，两个外观 | 系统自己裁圆角；App Store Connect 拒收带 alpha 的图标 |
| Live Activity | 32 / 64 / 96 白色模板，裁到环的外接框 | 素材分辨率不能超过它被绘制的尺寸；模板由系统着色 |
| Android | 192 满幅 + 24dp 通知矢量 | 与 iOS 同一份浅色母版；通知图标是掩膜 |

`make-app-icon.py` 只做三件事：把母版放到 1024 网格、转成无 alpha 的 RGB、把同一只环按模板尺寸
栅格化。它不重画图标。`Contents.json` 里是两个 1024：默认（浅色）和
`appearances: [{appearance: luminosity, value: dark}]`；iOS 18 起系统在深色模式下自动取后者。

## 2. 环的几何

以母版画布为 1：

| 量 | 值 | 说明 |
|---|---|---|
| 中心线半径 `R` | 0.385 | 五个元素的圆心 |
| 描边宽度 `W` | 0.086 | 圆头端点；深色母版略细、浅色略粗，取共用中值 |
| 墨迹外径 | 0.856 | `2 * (R + W/2)`；图标和标记都按这个比例 |
| 长弧 | 270° → 47°（137°） | 右上到右下 |
| 下弧 | 70° → 109°（39°） | 底部 |
| 左下弧 | 131° → 163°（32°） | 左下 |
| 左弧 | 186° → 206°（20°） | 左侧 |
| 圆点 | 230° | 十点钟；零长度弧就是一颗圆头点 |

角度从三点钟方向起、顺时针为正（视图的 y 轴向下）。`R`、`W`、五段角度在
`DSH-Mizar/Design/MizarRing.swift` 和 `icon-design/masters/mizar-icon/ring_geometry.py` 里各有一份；
`MizarRingTests` 钉住它们，改一处必须改另一处。

## 3. 四种动作

四种都只由时间轴和五个元素的 trim 决定，没有整体旋转：每一帧都是图标在“被画出来”的某个状态，
而不是一只转动的通用 spinner。

### running —— 链式队列循环（1.51 秒一圈）

第一帧就是**已经完整存在的五个圆点队列**，没有淡入/缩放/移动出场；最后一帧也是同一个队列，
没有淡出/离场。整个循环是：

`五点队列 → 链式延展 → 完整图标 → 链式收缩（同时聚拢） → 同一个五点队列`

**初始队列**（gap 来自最终图标，不是均分）：

```text
G = [23, 22, 23, 24]            // 长弧→下弧→左下→左→点
s = [270, 293, 315, 338, 362]   // 12 点附近排到约 3 点
A = 362°                        // 最后方的点
```

| 阶段 | 内容 | 时长 |
|---|---|---|
| A | 五点队列（首帧即完整，短暂停留） | 0.18s |
| B | 链式生长：`s(i+1)=s(i)+L(i)+G(i)`（错峰 0.055 / 0.38） | 0.60s |
| C | 完整图标 | 0.15s |
| D | 链式收缩：长度减小，位置由同一约束实时重算，队列同步聚拢 | 0.58s |
| **一圈** | | **1.51s** |

- **没有出场/离场**：不执行 Scale、Opacity、Position 的首尾动画；第一帧和最后一帧是同一个
  五点队列（数量、顺序、尺寸、透明度、间距、整体位置全部相同）。
- **生长**：长弧先长，`s(i+1)` 用当前长度实时重算，后面的点被顺时针挤走；最终
  `L=[137,39,32,20,0]` 时 `s=[270,430,491,546,590]` 归一化为原图标的
  `[270,70,131,186,230]`。
- **收缩前沿顺时针**：每条弧有一个可见的收缩前沿 `F(i)`，剩余圆弧是 `F(i)..T(i)`：
  - 第一条弧的前沿从 270° 顺时针走一整圈，`F(0) = 270 + 360e`；
  - 每条弧的尾端 `T(i) = F(i) + L(i)`；
  - 后一条弧的前沿 `F(i+1) = T(i) + G(i)`，间距在每一帧成立；
  - `L(i)` 连续减小，`F(i)` 和 `T(i)` 都只向顺时针方向移动；前沿追上尾端时圆弧变成圆点。
  这不是 `trimEnd` 从 1 反向降到 0，也不是整段同步缩短；剩余圆弧始终在前沿的顺时针一侧。
- **收缩是一个过程**：每段长度按自己的曲线缩短，**同一帧**用同一个链式约束重算所有起始位置；
  队列在收缩中连续聚拢，没有“先变成分散五点、再执行归位”的第二段。
- **调试预览**：`MizarRing(..., debugShrinkFronts: true)` 在每个前沿画白底红圈的小点，用来确认
  前沿只向顺时针移动。正式 UI 默认关闭。
- **独立圆点**：不单独做归位动画；它的位置由链式约束在收缩过程中连续算出，最后落在 A。
- 所有元素共用一个 `TimelineView(.animation(minimumInterval: 1/120))` 时钟；状态由
  `positionOffset`（相对最终 start 的当前起始角）和 `sweepScale`（当前长度/最终长度）描述。
- 曲线：生长 ease-in-out + 一次局部超调（弧长 ~1–2%、描边 2%、径向 0.3%）；收缩 ease-in-out
  sine；不是所有属性共用一个 easing。
- 应用内的运行指示 / 加载仍用这个完整循环；设置页头部改用下面的一次性 `assembling`。
- 首尾都是完整五点队列，循环边界没有空白帧、淡入淡出或位置跳变。

### assembling —— 设置页一次性加载（0.78 秒）

只从五个点长到图标，不循环：

- 前 0.18s 保持完整五点队列；
- 之后 0.60s 按同一链式约束生长到完整图标；
- 结束就停在图标，没有收缩、没有淡出、也不重复。

设置页每次打开由 Sidebar 递增 `animationToken`、`MizarIconTile` 用 `.id(token)` 重建；视图出现
后等 0.45s（让 sheet 升起来）再播一次，所以用户能看到五个点开始。动画本身是
`RingPresentation.assembling(0...1)`，`0` 是五点队列，`1` 是完整图标。

用在：设置页头部（64pt）。

### once —— 短加载与过渡（1.58 秒一次）



从静态图标开始：先停 0.14 秒，然后按 running 的顺序收起五段（0.56s），空环停 0.12s，再按同一
顺序画回来（0.62s），最后停在完整图标 0.14 秒。它开头和结尾都是图标姿势，所以可以直接盖在任何
显示图标的屏幕上而不会跳帧。

用在：登录墙顶部（92pt）。

### opening —— 进度读数

不是装饰，是下载 / 同步的进度：从缺口（270°）开始顺时针填，`0` 是空环加一圈 12% 的淡轨道，
`1` 是完整图标。弧按经过的角度裁切，圆点在头部越过 320° 时淡入并长大。Reduce Motion 下仍然随
进度变化，只是不做额外缓动。

用在：配对后的首次全量下载（96pt）、刷新进度窗（56pt）。

### Reduce Motion

- `running` 停在完整图标；`once` 直接显示最后一帧；`opening` 跟随进度。
- 动画不承担信息时（装饰）就停；承担读数时（opening）保留变化。

## 4. 颜色

| 外观 | 环 | 底板 | 强调色 | 强调色上的墨 |
|---|---|---|---|---|
| 浅色 | 蓝→青渐变 `#3E86F0` / `#5DC4F9` / `#7FE4FC` | 近白 + 淡蓝径向光 | `#3CCBF4` | `#03141F` |
| 深色 | 白 | `#1A1A1A` | 白 | `#03141F` |

- 浅色强调色是图标里最亮的那档青蓝，用在填充、开关、进度环和主按钮上。
- 因为它是亮色，主按钮的墨改成近黑（`Theme.onAccent`），不再用白字压亮青。
- 文字 / 小图标另用 `Theme.accentText`：浅色是 `#0A78AE`（同一色相压深到白底上可读），
  深色是白色。填充仍用 `Color.accentColor`，所以“亮青”体现在面上，“深青 / 白”体现在字上。
- 图标砖（设置页头部）用 `MizarIconTile`：浅色是近白底 + 淡蓝径向光 + 蓝青渐变环，深色是
  `#1A1A1A` 底 + 白环；圆角 22.37%，环占 85.6%——都是图标的数。

## 5. 标记出现在哪里

| 位置 | 代码 | 形态 |
|---|---|---|
| OS 图标 | `Assets.xcassets/AppIcon.appiconset` | 两个 1024 PNG（浅色 / 深色） |
| 设置页头部 | `MizarIconTile(size: 64, motion: .assembling, animationToken:)` | 图标砖 + 一次性五点→图标（停住） |
| 登录墙 | `MizarRing(motion: .once, size: 92, palette: .ink(.white))` | 白墨 |
| 连接中 | `LaunchingView` 的 `MizarRing(motion: .running, size: 64)` | running |
| 配对搜索 | `MizarRing(motion: .running, size: 56)` | running |
| 未配对首屏 | `MizarRing(motion: .running, size: 112, palette: .ink(.white))` | running |
| 同步（首次 / 刷新） | `MizarRing(motion: .opening(fraction), size: 96 / 56)` | opening；无进度时 running |
| 会话运行指示 | `MizarRing(ink: 14…17, motion: .running)` | 随外观；深色白 |
| 灵动岛与实时活动 | `DSH-Mizar-LiveActivity/…/MizarIcon.imageset` | 白色模板，静态 |

浅色设置页实拍：[`../../docs/evidence/ios-settings-ring-2026-11-07.png`](../../docs/evidence/ios-settings-ring-2026-11-07.png)。

**Home 没有大标记**：首页问候不再放应用图标，避免每进一次首页就播一次品牌动画。

**灵动岛为什么是静态的**：Live Activity 是系统在应用之外渲染的快照，不接受连续自定义动画，也不
链接应用里的 SwiftUI `Canvas`；它的素材尺寸还有上限。所以那边只有环本身，没有时间轴。

## 6. 测试

- `DSH-MizarTests/MizarRingTests.swift`：25 个用例——五段顺序与不重叠、R/W/墨迹比例、圆弧路径
  包围盒、多种缓动、起始时刻慢-快-慢、morph 单次超调、链式挤压、首尾五点队列、连续收缩同步聚拢、短过渡首尾为图标、settings 一次加载、进度读数顺时针且单调、圆点最后亮、
  只有 opening 画轨道。
- `DSH-MizarTests/SnapshotTests/MizarRingSnapshotTests.swift`：图标 / 空轨道 / 半满 / 白墨 / 深色
  五种环姿势，加图标砖浅色与深色两张；参考图在 `Snapshots/__Snapshots__/`。
- `UnpairedLaunchSnapshotTests`：未配对整屏，注入静止的白墨环。
- 动画本身无法断言（`TimelineView` 没有可步进的测试时钟），所以测的是“决定”而不是“效果”；
  2026-11-07 版逐帧证据在 [`../../docs/evidence/ios-ring-motion-2026-11-07.png`](../../docs/evidence/ios-ring-motion-2026-11-07.png)。
  2026-11-08 的链式队列连续循环预览见
  [`../../docs/evidence/ios-ring-loop-2026-11-08.gif`](../../docs/evidence/ios-ring-loop-2026-11-08.gif)，
  收缩前沿调试预览见
  [`../../docs/evidence/ios-ring-shrink-fronts-2026-11-08.gif`](../../docs/evidence/ios-ring-shrink-fronts-2026-11-08.gif)
  与
  [`../../docs/evidence/ios-ring-shrink-fronts-2026-11-08.png`](../../docs/evidence/ios-ring-shrink-fronts-2026-11-08.png)。
  红白小点就是每条弧的收缩前沿；录屏用临时 160pt debug ring，生产用同一个 `MizarRing`。

## 7. 重建与验证

```sh
cd iOS

python3 scripts/make-app-icon.py          # 图标 + 灵动岛模板
python3 scripts/make-app-icon.py --check  # 应该输出 up to date

# 图标和 Live Activity 模板必须无 alpha：
sips -g hasAlpha DSH-Mizar/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png
sips -g hasAlpha DSH-Mizar/Assets.xcassets/AppIcon.appiconset/AppIcon-1024-dark.png

OTHER_SWIFT_FLAGS='-disable-sandbox' scripts/ios.sh build
```

桌面端的图标由 `AGI Mizar/scripts/make-icons.py` 从同一份母版生成；它还需要 `iconutil` 来写
`.icns`。Live Activity 的模板由 `make-app-icon.py` 用 `ring_geometry.py` 直接画，而不是把图标
缩小的位图：96px 时把 706px 的 alpha 阈值化会看到阶梯状端点。
