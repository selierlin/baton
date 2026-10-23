# Baton

macOS 常驻工具（剪贴板 / 输入法 / 平滑滚动 / 截图 / OCR / 翻译 / 贴图），纯自用。
方案见 vault：`编程｜program/MacOS/Baton/Baton-方案设计-v2.1.md`。

当前进度：**P1–P7 全部完成**。208 个单测通过，`dist/Baton.app` 可直接日常使用。

| 模块 | 状态 |
|---|---|
| 剪贴板历史 / 输入法记忆 / 平滑滚动 | 可用 |
| 截图（区域 / 窗口 / 元素）+ 标注 | 可用 |
| OCR（Vision / 百度，子进程隔离） | 可用 |
| 翻译（百度 API 实测 436 ms） | 可用 |
| 贴图 / 长截图 / 尺子 | 可用 |

## 结构

```
Sources/BatonCore
├── AppShell.swift             菜单栏、动作分派、激活策略、截图入口
├── EventHub.swift             输入事件总线（前台 App / 剪贴板 / 滚动 tap）
├── HotkeyRegistry.swift       Carbon 热键 + 冲突检测 + tap 兜底去重
├── HotkeySettings.swift       8 个动作 + 覆盖项持久化
├── HotkeyAudit.swift          自重复 / 撞系统符号键检查
├── CaptureGeometry.swift      全局坐标 ↔ 屏内像素 ↔ Cocoa 坐标
├── ScreenCapturer.swift       区域抓帧 + RegionCaptureSession（复用 SCK filter）
├── OverlayKit.swift           冻结帧覆盖层 + overlay 残留保护 + 长截图模式
├── CaptureSession.swift       intent / action 两阶段会话
├── ActivationPolicy.swift     .accessory ⇄ .regular 引用计数切换
├── LoginItem.swift            SMAppService 封装
├── PermissionCenter.swift     权限查询与系统引导
├── Annotate/                  画布、工具条、模型、渲染、导出、就地标注
├── Stitch/                    FrameStitcher、采集循环、会话合成
├── Recognize/                 OCRTransport（Vision / 百度 / 子进程）
├── Translate/                 provider、选区取词、面板、Keychain
├── Clipboard/                 GRDB 存储、面板、粘贴板读取
├── InputSource/               TIS 目录、规则、服务
├── Pin/                       贴图窗口、位图源、持久化
├── Ruler/                     尺子画布、度量、吸附
├── SmoothScroll/              纯插值计算 + 120Hz 重放
├── UI/                        偏好设置（工具栏切页）+ 统一行式版式 + 提示面板
├── Diagnostics/               动作日志、主线程看门狗
└── Support/                   表单编码等小工具

Sources/BatonApp          App 入口（含 --stitch / --ocr / --scroll-* / --prefs 等诊断参数）
Sources/BatonOCR          OCR 子进程（空闲 20 s 自退）
Sources/BatonProbe        冒烟探针（CLI）
Scripts/make-app.sh       打包成 dist/Baton.app
Tests/BatonCoreTests      226 个单测
```

## 四个接口的边界

- **EventHub**：只产事件，不做平滑、不做规则匹配。平滑通过 `scrollInterceptor`
  外挂（返回 true 表示事件已被接管），拦截型 tap 与只监听 tap 是两种模式，切换要重建。
  滚动事件用 `.bufferingNewest(1)`，订阅者拿到的永远是最新位移。
  `noteSelfPasteboardWrite()` 必须在自写剪贴板后调用，否则会自我繁殖。
- **HotkeyRegistry**：只负责注册与派发。冲突返回 `HotkeyError.conflict`（Carbon `-9878`），
  是否降级 tap 由调用方决定；`TriggerDeduplicator` 只抑制「tap 紧跟 carbon」，
  不抑制用户快速连按。
- **OverlayKit**：只负责画冻结帧和收框选。返回 `CaptureSelection`（全局点坐标），
  不认识 OCR / 翻译 / 贴图。`OverlayRecovery` 写 `~/Library/Application Support/Baton/overlay.lock`。
- **CaptureSession**：编排权限预检 → 抓帧 → 框选 → 产出 `CaptureResult`。
  `.scroll` 走不了这里（冻结帧会让页面不动），P6 另开实时抓帧路径。

## 关键实现约定

- **`SCDisplay.width/height` 是点，不是像素**，必须乘 `filter.pointPixelScale`；
  不设 `configuration.width/height` 会得到固定的 1920×1080。
- 非光标屏按 0.5x 抓，`DisplayFrame.captureScale` 用「像素 / 点」算，
  降采样时必须用它而不是 `nativeScale`。
- SCK 的 `CGImage` 由 IOSurface 支撑，**不计入 footprint**。内存只能按
  `bytesPerRow * height` 估。
- 冻结帧直接赋 `CALayer.contents`，不要过 `NSImageView`。
- **剪贴板采集要重试**：刚变更时可能读到「有类型但长度 0」，这种空读不改变
  `changeCount`，不重试这条就永久丢了。
- **剪贴板来源 App 要现查**：`EventHub` 缓存的 frontApp 只在 App 激活时更新，
  复制动作本身不激活 App。
- **浮窗不要用 `hidesOnDeactivate`**：accessory App 的激活可能被系统拒绝，
  窗口会立刻消失。改用 `orderFrontRegardless()` + 自己监听 `didResignActive`。
- **投递滚轮事件要同时写 5 个字段**：`IsContinuous`、`PointDeltaAxis1/2`、
  `FixedPtDeltaAxis1/2`、`ScrollPhase`。只写 `DeltaAxis` 的话，读
  `scrollingDeltaY` 的 App 会当成 0，看起来就是「滚了没反应」。
- **拦截型 tap 必须给自投事件打标记**（`eventSourceUserData`）。`.headInsertEventTap`
  能看到自己投的事件，不打标记会无限自激。

## 运行

```
swift build
swift test                            # 223 个单测

./Scripts/make-app.sh                 # 打 dist/Baton.app（自动取本机开发证书签名）
open dist/Baton.app                   # 菜单栏出现图标

# 装到 /Applications 并开自启（日常用这一份）
ditto dist/Baton.app /Applications/Baton.app
/Applications/Baton.app/Contents/MacOS/Baton --login-enable

# 冒烟探针（CLI）
swift run BatonProbe                  # 打印权限、注册热键、监听事件
swift run BatonProbe capture          # 框选一次，打印选区像素矩形
```

界面遵循 macOS 惯例：状态栏菜单按「截图 / 录制 / 贴图 / 工具 / 高级」分组，
最常用的两项（区域截图、长截图）留在外面；设置窗口用 `NSToolbar`（`.preference` 样式）
切页，每页统一 20pt 边距、左边标题右边控件，窗口高度按当前页内容自动量。

## 日志：出问题先看这个

每条用户操作、结果、失败原因都写进 `~/Library/Logs/Baton/baton.log`（超过 4 MB 轮转成 `.1`）。
菜单 **高级 → 打开日志文件夹** 直接定位；遇到问题把这个文件发出来就能复盘。

```
16:03:54.148 [action] menu                       item=设置… selector=showPreferencesFromMenu
16:03:54.150 [action] prefs.open                 tab=0
16:05:12.001 [action] hotkey                     action=pin title=截图贴图
16:05:12.003 [action] capture.begin              intent=area action=pin front=Google Chrome
16:05:13.402 [result] capture.done               rect=1200,300 600x400 px=2400,600 1200x800 ms=1399
16:05:13.431 [result] pin.show                   count=1 px=1200x800 scale=2.0 at=1200,300
```

七种行：`app` 生命周期、`action` 用户意图、`result` 成功路径的数据、`fail` 失败/降级、
`modal` 提示面板进出、`state` 内部状态切换。

两条排查经验：

- **`modal open` 没有配对的 `close`** = 面板弹出来但没被处理（曾经就是「点一下整个 App 卡死」的形态）
- **`main.stall` / `main.recovered`** 由看门狗写入：主线程连续 8 秒没响应就记一条，
  恢复后补一条耗时。日志里看到 `main.stall` 就是真卡了，不是错觉

提示面板为什么不是 `NSAlert.runModal()`：Baton 是 `.accessory` 应用，从状态栏菜单项触发时
**无法激活自己**（实测 `setActivationPolicy(.regular)` + `activate()` 等 2 秒仍是 `isActive == false`）。
`runModal` 会先占住主线程，窗口停在「已 order 但没上屏」，菜单也被模态循环吃掉 —— 用户看到的就是卡死。
现在统一走 `ModalAlert` 的非模态浮动面板（`.floating` 级 + `orderFrontRegardless()`），
和贴图窗口同一套机制，不依赖激活、不阻塞主线程。

编辑态里点工具条会把整场截图退掉：`OverlayView` 的 `mouseDown` / `mouseUp` 靠 `lockedSelection`
判断是不是编辑态，而属性条里的自绘控件（颜色圆点、分段选择、下拉）只实现了 `mouseDown`，
`mouseUp` 会顺着响应链冒到覆盖层 —— 覆盖层按「空选区 = 取消」处理，于是「点一下颜色，截图没了」。
现在两头都堵：`mouseUp` 先判 `lockedSelection`，`AnnotatePropertyBarView` 也吞掉 `mouseUp`。
日志里对应的痕迹是 `overlay.cancel src=maskUp empty=none`。

拖框时放大镜「慢半拍」不是刻意的缓动，是 Core Animation 的隐式动画：`CALayer` 挂在 `NSView`
的图层树上，改 `frame` / `path` / `contents` 默认带 0.25s 缓动。
实测改完 `position` 立刻读 `presentation()`，屏幕位置还停在 190pt 之前 —— 肉眼看到的就是放大镜
和选区边框追着光标跑。现在覆盖层里所有逐帧更新都包在 `CATransaction.setDisableActions(true)` 里，
另外同一像素格内不再重设 `contents`，省掉一次纹理上传。

跟手的另一半是**谁来驱动刷新**。Longshot 的二进制 `nm -u` 里有
`CVDisplayLinkCreateWithActiveCGDisplays` / `SetOutputCallback` / `Start`，它是在 vsync 回调里
每帧读一次光标；Baton 原来是纯 `mouseMoved` 事件驱动 —— 系统会合并/丢弃移动事件，一帧里可能
到 0 个也可能到 3 个，放大镜的位移节奏就跟着事件抖，看起来「跟不上、眼睛没法跟」。现在改用
macOS 14 的 `NSView.displayLink(target:selector:)`（等价物，回调在主线程、跟屏幕刷新率走），
每帧取一次 `NSEvent.mouseLocation`。实测 60Hz 下每帧 `updateMagnifier` 耗时 0.9~1.0ms、
最大 2ms，帧间隔稳定 167ms/10 帧。

位置仍然吸附到整点：内容是按整像素裁的，框走小数会出现「框在平滑滑、里面的格子整块跳」，
两者必须同节奏。贴边翻转加了 8pt 迟滞，否则光标压在阈值上时框会在左右/上下之间来回横跳。

放大镜的规格是量 Longshot 量出来的，不是凭感觉调的：`strings` + `nm` 能翻到它没被 strip 的
Swift 反射字段（`snipMagnifierLabel`、`snipMagnifierColorStylePopUpButton`、
`snipMagnifierHexColorHeadingPrefixCheckBtn`、`magnifierScale`），`zh-Hans.lproj` 里能翻到
`snip_captureCursor_positionPrefix` = `坐标: ` / `dimensionPrefix` = `区域: ` /
`colorPrefix` = `色值: `，偏好 plist 里能翻到 `snipMagnifierColorStyleRawValue`。剩下的
尺寸、倍数、间距是从截图上按像素量出来的：外框 270×382 px（2x）= 135×191 pt，网格 18 px
一格，正好 15 格。

「一格代表屏幕上多少」不能靠猜，得拿两张帧对齐量：把光标挪 1pt 再截一张，用掩掉网格线的
互相关找位移 —— Longshot 的格心正好移动 18 个设备像素 = 一格。所以**一格 = 屏幕 1pt**，
15 格盖住 15pt（2x 屏 30 个设备像素），倍率是 9 倍而不是 18 倍。之前按「一格一个位图像素」
裁 15 px，一步要跑两格，HJKL 按三下就走完了四格 —— 那才是「移动不是一个像素」的真凶。

网格线要「看得清每一颗像素」而不是一片糊，参数是反解出来的而不是调出来的：格底
(44,52,64)、线 (104,109,116)，按白色叠加逐通道解 alpha ≈ 0.28；线宽 2 px（2x 屏 = 1 pt）。
十字带量到合成色 (34,92,160)，反解 `#0084FF` 叠在格底上 alpha = 0.5；带内网格线会透出来
（95 → 124），和 Longshot 一致。中心取色格是外沿 25 px、内空 16 px、描边 4~5 px，折算
10.25 pt 中心线 + 2.25 pt 描边。

早先这里是 `NSImage(size:)` + `lockFocus` 画 1 pt 灰线，得到 1x 位图，铺到 2x 屏上放大两倍
再插值 —— 线发虚、颜色又只有 26% 灰（叠出来亮度 66 而不是 110），所以看起来像素线很淡。
现在按 backing scale 造 2x 位图、按像素填色，1:1 映射不缩放，量到的亮度才和 Longshot 对上。

十字辅助线只在放大镜方框内画，不向全屏延伸。曾经加过贯穿全屏的准星线，实际用起来是在画面
正中压两条线：拖框时看的是边缘和内容，全屏线只会盖住要对比的东西，Longshot 也没有。

长截图（`.scroll`）故意不带悬停拾取：滚动会话要的是精确的滚动区域，鼠标一动就亮一个窗口框
反而干扰判读。

`CGWarpMouseCursorPosition` 和 `CGDisplayMoveCursorToPoint` 都只能落在整点上：传 0.5 会被
舍回原值，连按十次光标纹丝不动（实测两个 API 行为一致）。Longshot 用的也是
`CGDisplayMoveCursorToPoint`，所以它的「1 个像素」同样是 1 个整点，不存在亚像素魔法。

真正让手感「不是一个像素」的是坐标换算：早先 `nudgeCursor` 走「视图本地 → 窗口 → 屏幕」
三次往返再 warp，任何一步带出 `.5` 都会被 warp 再舍一次，位移就在 1 和 2 之间跳。现在先
取整当前屏幕点，只加一次步长，后面的换算纯为刷新放大镜，不回灌到步长里 —— 实测连按 5 次
严格 -1、再按 3 次 J 严格 +1。

提示条用 `NSView` + `autoresizingMask` 贴左下时，`.maxXMargin` / `.maxYMargin` 会在
`addSubview` 时把 20.5pt 的底边距「吸收」成高度：结果是整条贴着屏幕底边、还高了 20pt。
覆盖层窗口每次按屏新建、尺寸不会中途变，不需要弹性，删掉 mask 就好。

提示条文案照抄 Longshot `SnipLocalizable.strings` 的 `snip_body_labelShortKey*`。它未圈选
时那套是 11 行，Baton 目前只列 7 行：多窗口 Shift、截图阴影 S、回溯区域 B/⇧B、回溯截图
`,`/`.` 这四项还没有对应实现，按了不会有反应，所以不写 —— 假提示比缺一行更糟。

日常运行的是 `/Applications/Baton.app`（已注册登录项）。改完代码要重新 `make-app.sh` 并 `ditto` 覆盖过去再重启，否则跑的还是旧副本。同一证书签名，覆盖重签不会掉 TCC 授权。

`capture` 需要屏幕录制权限；滚动事件需要输入监控权限；元素拾取需要辅助功能。

签名说明：`make-app.sh` 默认从 `security find-identity` 取 Apple Development 证书。
ad-hoc 签名每次重建 cdhash 都变，TCC 授权会静默失效（界面勾选还在，实际返回 `-25211`），
所以别图省事用 `-s -`。
### 剪贴板历史（P2）

启动后按 **⇧⌘V**（或菜单栏 → 剪贴板历史）：

- `↑↓` 选择，`↵` 复制并关闭，`⌘↵` 复制并粘贴到前台 App，`⎋` 关闭
- 搜索框支持中文两字词（FTS5 trigram 对 <3 字符无效，已降级 LIKE）
- 库文件：`~/Library/Application Support/Baton/baton.sqlite`，图片在 `blobs/`
- 机密类型（`ConcealedType` / `TransientType` / 密码管理器标记）一律不落库
- 上限 800 条；裁剪跳过被钉住的条目；blob 用孤儿 GC 回收

冒烟：`dist/Baton.app/Contents/MacOS/Baton --clip-panel`（1 秒后自动退出）

### 输入法记忆（P2）

默认开启，菜单位置：菜单栏 → 按 App 记住输入法。

- 切走时记住当前 App 用的输入源，切回来自动恢复；**没有记录就不动**，
  不强行切回某个"默认源"
- 显式规则优先于记忆（`setRule(bundleID:sourceID:)`，UI 还没做）
- 设置文件：`~/Library/Application Support/Baton/input-source.json`
- 不需要任何隐私权限（TIS 本身不受 TCC 管）

诊断：

```
dist/Baton.app/Contents/MacOS/Baton --input-sources          # 列出已启用、可选的源
dist/Baton.app/Contents/MacOS/Baton --input-switch <id>      # 直接切（会改系统状态）
```

### 截图三种进入方式（P3）

菜单栏 → 区域截图 / 窗口截图 / 元素截图。

- 区域：拖框自由框选，光标旁跟一个 15×15 格的放大镜（一格 = 屏幕 1pt，9 倍），底部三行报坐标 / 区域 / 色值
- 区域入口同时就是「开始截图」：鼠标停在窗口或元素上会先把那块框出来（标签报出它是什么、多大），
  单击即选（位移 < 3pt 才当单击，动一下就转成自由框选），不必先切到窗口/元素截图
- 窗口：悬停高亮整窗，单击确认
- 元素：悬停高亮 AX 元素（按钮、输入框、文本块），单击确认；App 不支持 AX 时自动退化成整窗

还没圈选时，左下角有一列快捷键提示。样式是量 Longshot 的截图界面得出的：70% 黑底、13pt 白字、
行距 23pt、圆角 3pt、左 10pt 底 20.5pt，每行「动作: 键」。

| 键 | 动作 |
|---|---|
| ⇥ | 在「窗口区域（AX 元素）」和「整窗」之间切 |
| F | 整屏当选区 |
| ↩ | 选中光标下的窗口/元素 |
| K J H L | 光标上 / 下 / 左 / 右移 1pt |
| C | 复制光标所在像素的颜色（`#RRGGBB`） |
| T | 切换放大镜色值样式：hex → rgb → hsl |
| ⎋ / 右键 | 退出截图 |

长截图那条路径故意不挂悬停拾取（滚动会话要的是精确滚动区域），所以它的提示条只有
HJKL / F / C / T / ⎋ 五行 —— 提示条只列真能按的键，不写按了没反应的。

区域/窗口/活动窗口截完都直接进标注；元素截图和「截取上一次区域」的另存版本走别的出口。
延迟截图的秒数在 设置 → 通用 → 延迟截图 里选（3 / 5 / 10 / 15 秒），倒计时期间按 Esc 取消。

实现要点：

- 覆盖层是最前面的窗口，所以**不能用 `AXUIElementCreateSystemWide()` 做命中**——会返回我们自己的
  overlay。改为先用 `CGWindowListCopyWindowInfo` 找到光标下的窗口，再对**那个 App 的** AX 树
  `AXUIElementCopyElementAtPosition`。
- 窗口列表按 120 ms 缓存，鼠标在窗口内移动不会反复枚举。
- 跨屏窗口只取光标所在屏那一段（抓帧与裁剪都是逐屏的）。
- 命中常落到 `AXStaticText` 上，只向上收一层到两层，不往整窗爬。

诊断（不需要开覆盖层）：

```
dist/Baton.app/Contents/MacOS/Baton --pick-probe 700 500 window
dist/Baton.app/Contents/MacOS/Baton --pick-probe 700 500 element
```

输出会列出该点命中的所有候选窗口，`element` 模式额外打印 AX 错误码、角色与矩形，
便于区分「AX 没命中」和「命中但框太小被退回整窗」。

### 平滑滚动（P2）

默认开启，菜单位置：菜单栏 → 平滑滚动（滚轮）。

- **只处理离散滚轮**。触控板 / 妙控板发出的 `isContinuous == 1` 事件直接放行——
  系统已经做过插值和惯性，再平滑会变成双重曲线
- 拦截型 tap 需要「辅助功能」；没有权限时自动退回只监听，不会连累其它功能
- 一次滚轮位移被摊成 120 Hz 的小位移，`duration` 控制尾巴长度，`maxPending` 防止连滚拖尾
- 自投事件带 `eventSourceUserData = 0x4241544F`，tap 里先判标记再放行，否则会自激
- 参数：`~/Library/Application Support/Baton/scroll.json`

诊断：

```
dist/Baton.app/Contents/MacOS/Baton --scroll-status        # 参数 + 权限
dist/Baton.app/Contents/MacOS/Baton --scroll-smooth on|off # 改开关
dist/Baton.app/Contents/MacOS/Baton --scroll-watch 30      # 打印原始滚动样本
dist/Baton.app/Contents/MacOS/Baton --scroll-selftest      # 投 3 格滚轮验证拦截+重放
```

`--scroll-watch` 用来确认设备类型：外接鼠标应报 `continuous=0`，触控板报 `continuous=1`。
`--scroll-selftest` 会让光标下的窗口真的滚动几行，输出形如：

```
tap active=true intercept=true reason=-
swallowed=3 posted=64
```

### 登录项（SMAppService）

必须在 .app 内运行才有效。诊断参数：

```
dist/Baton.app/Contents/MacOS/Baton --login-status
dist/Baton.app/Contents/MacOS/Baton --login-enable
dist/Baton.app/Contents/MacOS/Baton --login-disable
```

实测（2026-10-18）：Apple Development 证书签名、放在 `/Applications`、`lsregister -f` 之后
`--login-enable` 返回 `status=1 已启用`，`--login-disable` 返回 `status=0 未注册`。
注册前 `status` 是 `.notFound`（3），这是「服务尚未登记」，不是「bundle 不合法」。
没有出现评审所说的 error 1（该说法无依据）。

注意：`--login-enable` 会真的添加登录项，测试完记得 `--login-disable`。

### 长截图（P6）

默认 **⌥⌘L**（设置 → 热键可改）：框选区域 → 手动滚动 → 停手 4 秒自动完成 → 进标注窗。

- **滚动中 90 ms 抓一帧**，停手后回到 500 ms；`RegionCaptureSession` 复用 SCK filter，单帧约 42 ms
- **单帧位移 ≤ 0.75 屏才拼接**。超出即「超速」：HUD 变橙字，换基线处会在成图上叠一条黄底断点带「拼接断点 · 此处内容未被拍到」
- 往上回滚不重复追加：基线钉在已截最深处，等重新往下滚过基线再继续
- 拼接校验三重：谷底唯一 + 模板 MAE ≤ 7 + 全重叠区 MAE ≤ `max(12, 模板误差×3)`
- 上限 12000 物理像素；逐帧日志在 `~/Library/Logs/Baton/stitch-*.log`
- HUD 里 `↩` 完成、`Esc` 取消；滚到页面底部回弹时不会再把停手计时顶掉（回滚最多宽限 3 秒）

诊断（跳过框选与热键，配合外部投递滚轮可脚本化复现）：

```
dist/Baton.app/Contents/MacOS/Baton --stitch 90 130 880 700 /tmp/out.png
BATON_STITCH_DEBUG=1 ...                    # 逐帧打印 adv/back/still/miss
```

### 标注（P5）

**⌥⌘A** 框选后进标注窗。十种工具，键位沿用 Longshot：
`1` 矩形 / `2` 直线 / `3` 马赛克 / `4` 高亮 / `6` 画笔 / `7` 文字 / `8` 序号 / `9` 椭圆 / `0` 鱼尾箭头 / `V` 选择，
`P` 贴图 / `↩` 复制 / `⌘D` 保存 / `⌘Z`、`⇧⌘Z` 撤销重做 / `Esc` 取消。

长图会开在**可滚动**窗口里：窗口高度按可视区算，滚轮在长图场景归滚动（改线宽/字号用属性条滑杆），普通截图仍保留滚轮调粗细。

### 贴图（P5）

**⌥⌘P** 把当前截图钉在屏幕上。滚轮 0.25–4× 缩放，双击在「100% ⇄ 适配屏幕」间切换，右键菜单给倍率/不透明度/置顶/复制/关闭，`Esc` 关。
按窗口设备像素重采样（不是把原图直接缩），落库后原图释放，显示走子采样解码。

### OCR / 翻译（P4）

- **⇧⌘O** 截图 OCR、**⇧⌘Y** 截图翻译、**⇧⌘T** 划词翻译（Chrome / Safari / TextEdit 实测可用）
- OCR 默认走 `BatonOCR` 子进程（常驻 15 MB，空闲 20 s 自退），失败自动降级进程内
- 翻译走百度 API（436 ms），key 在「设置 → 翻译 / OCR」里配，落 Keychain 不进配置文件
- 划词取词两段式：先 `AXSelectedText`，拿不到再走 WebKit 的 `AXTextAttributedStringForTextMarkerRange`

### 尺子（P6）

**⌥⌘R** 进测量模式，可量像素并取色。

### 录制（P5）

菜单栏四个入口，热键可改：

| 模式 | 默认热键 | 选目标方式 |
|---|---|---|
| 区域录制 | `⌃⌘8` | 框选区域（和截图同一个覆盖层） |
| 全屏录制 | `⌃⌘9` | 鼠标所在屏，直接开录 |
| 窗口录制 | `⌃⌘0` | 点一个窗口 |
| 应用录制 | `⌃⌘-` | 前台 App |

- 选区外沿画 2pt 红框 + 左上角 `REC` 角标，录制期间一直可见；区域/窗口/应用三种模式都有，整屏没有
- 区域录制的红框就是刚才框选的那块，工具条贴在框下沿；框选结束到开始录制之间不会闪掉覆盖层
- 工具条贴在选区正下方（下方放不下翻到上方，左右夹在屏幕内）：红点 + `mm:ss` + 暂停/继续 + 停止（`Esc`）/ 取消；不抢焦点，录的时候可以正常操作被录的 App
- 边框和工具条是 Baton 自己的窗口，在 `SCContentFilter` 里整个 App 被排除，**成片里不会混进去**
- 暂停不留静止画面：暂停期间的样本直接丢弃，继续时用 `CMSampleBufferCreateCopyWithNewTiming` 把后续时间戳整体前移
- 停止 → `~/Movies/Baton/Baton-yyyyMMdd-HHmmss.mp4`，弹出预览窗：可以直接播放、复制、在 Finder 中显示、
  移到废纸篓；空格播放/暂停、Esc 关掉。**不主动激活 Finder**（那会把用户的窗口切走）。取消 → 删文件
- 菜单栏图标录制期间变红色 `record.circle.fill`，菜单里「停止录制」同时可用
- 带系统声音（AAC 48kHz 立体声，走 SCK 的 `capturesAudio`，不需要麦克风权限）；
  设置 → 通用可以关掉「录制系统声音」。H.264 / MP4 / 12 Mbps，帧率 10–60（默认 30）
- 可带麦克风旁白（设置 → 通用「录制麦克风旁白」，默认关）。麦克风走独立的 `AVCaptureSession`
  采 48kHz 立体声 Float32，和系统声音在 `AudioMixer` 里**按时间轴相加成一轨**（80ms 前瞻等
  麦克风到场），所以成片永远只有一条音轨，播放器/剪辑软件不用处理多轨。峰值超 1 就削顶，
  不爆音；只开麦克风（关掉系统声音）也能单独录旁白
- 应用录制按该 App 所有 `windowLayer == 0` 窗口的并集裁切，不是整屏
- 探针：`dist/Baton.app/Contents/MacOS/Baton --record <full|window|app|area> 3 /tmp/out.mp4 [--mic]`
  （`--record-ui` 走完整控制条链路）；`--audio-probe <file>` 打印轨数、时长、峰值

## 尚未实现 / 已知边界

- **开机自启**：已启用。`/Applications/Baton.app`，`--login-status` 返回 `status=1 enabled=true`。**重启电脑才算真正验证**（状态位只证明登记成功，不证明被拉起）。
- **24h 连跑泄漏验收**：**已通过**。2026-10-21 21:10 → 10-23 09:56 单进程连跑 36h46m（442 个采样点）：
  footprint 18 MB → 20 MB（首尾差 +2 MB，峰值 21 MB 一次），前 5 小时 18 MB，10 小时后稳在 19–20 MB，
  之后 27 小时无爬升；RSS 75 MB → 14 MB（页被压缩/回收，属正常）。采样脚本 `Scripts/soak-sample.sh`
  仍在跑，每 5 分钟一条记到 `soak.log`。
- **输入法规则编辑 UI**：只有 API（`setRule(bundleID:sourceID:)`），没有界面；按 URL / 窗口标题匹配也没做。
- **麦克风旁白的时间对齐**：麦克风样本按 host clock 直接排进时间轴，没做 `CMSyncConvertTime`
  跨时钟换算。短录（几分钟）误差在毫秒级，长录理论上会有采样时钟漂移。
- **麦克风旁白的实机验证**：需要解锁屏幕后点一次系统授权框（锁屏状态下 TCC 直接拒）。
- **长截图能力边界**：单帧位移 > 0.75 屏（约 8 屏/秒）会被判「超速」拒拼，成图上留黄底断点带。这是设计取舍，不是缺陷——宁可缺一段并标出来，也不给错位的图。
- **长截图中间结果 mmap 落盘**：评估后暂不做。12000 px 上限下峰值 194 MB、收尾回落到 42 MB，上 mmap 收益不抵复杂度。
- 设计里列过但没进验收范围的三个动作：全屏截图、区域截图并复制、输入翻译（都没有设计细节）。
