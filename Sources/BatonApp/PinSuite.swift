import AppKit
import BatonCore

/// 贴图场景的自动跑测（`Baton --pin-suite`）。
///
/// 为什么不用单测：这一轮暴露出来的问题（光标不换、拖拽搬窗口、空格没反应）
/// 全都不是「算错了」，而是「AppKit 把事件送到了别处」或者「某个私有状态没跟着变」。
/// 单测调用的是我们自己的方法，天然绕过了那层，测不出来。
/// 所以这里开真窗口、发真鼠标事件（CGEvent），断言也读真状态。
///
/// 仍然测不了的：需要人眼判断的视觉问题、会弹模态框的流程（保存面板、右键菜单）。
/// 这些在 `docs/pin-test-matrix.md` 里标成「人工」。

@MainActor
final class PinSuiteReport {
    private var passed = 0
    private var failed = 0
    private var skipped = 0

    func check(_ id: String, _ title: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        if ok { passed += 1 } else { failed += 1 }
        let extra = detail()
        print("\(ok ? "PASS" : "FAIL")  \(id)  \(title)\(extra.isEmpty ? "" : "   [\(extra)]")")
        fflush(stdout)
    }

    func skip(_ id: String, _ title: String, _ why: String) {
        skipped += 1
        print("SKIP  \(id)  \(title)   [\(why)]")
        fflush(stdout)
    }

    var exitCode: Int32 { failed == 0 ? 0 : 1 }

    func summary() {
        print("---- \(passed) passed / \(failed) failed / \(skipped) skipped ----")
        fflush(stdout)
    }
}

// MARK: - 合成鼠标事件

@MainActor
enum PinEvents {
    static func sleep(_ ms: UInt64) async {
        try? await Task.sleep(nanoseconds: ms * 1_000_000)
    }

    /// 主屏高度：Cocoa 全局坐标（左下原点）与 CGEvent 坐标（左上原点）差这一截。
    /// 探针把窗口放在主屏上，所以不用管副屏。
    static var mainHeight: CGFloat { NSScreen.screens.first?.frame.maxY ?? 0 }

    /// 窗口坐标（左下原点）→ CGEvent 全局坐标（左上原点）
    static func global(_ point: CGPoint, in frame: CGRect) -> CGPoint {
        CGPoint(x: frame.minX + point.x, y: mainHeight - (frame.minY + point.y))
    }

    static func post(_ type: CGEventType, at point: CGPoint) {
        CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?
            .post(tap: .cghidEventTap)
    }

    /// 把鼠标挪过去。用 `mouseMoved` 事件而不是 `CGWarpMouseCursorPosition`：
    /// 后者只挪指针不送事件，`mouseMoved` 才能触发画布的悬停逻辑。
    static func hover(_ point: CGPoint) async {
        post(.mouseMoved, at: point)
        await sleep(220)
    }

    static func drag(from: CGPoint, to: CGPoint, steps: Int = 10) async {
        post(.leftMouseDown, at: from)
        for step in 1...steps {
            let t = CGFloat(step) / CGFloat(steps)
            post(.leftMouseDragged, at: CGPoint(x: from.x + (to.x - from.x) * t,
                                                y: from.y + (to.y - from.y) * t))
            await sleep(18)
        }
        post(.leftMouseUp, at: to)
        await sleep(280)
    }

    static func click(_ point: CGPoint) async {
        post(.leftMouseDown, at: point)
        await sleep(40)
        post(.leftMouseUp, at: point)
        await sleep(280)
    }

    /// 双击：`clickCount` 来自 CGEvent 的 clickState 字段，AppKit 会映射成 `event.clickCount`。
    static func doubleClick(_ point: CGPoint) async {
        for count in 1...2 {
            for type in [CGEventType.leftMouseDown, .leftMouseUp] {
                let event = CGEvent(mouseEventSource: nil, mouseType: type,
                                    mouseCursorPosition: point, mouseButton: .left)
                event?.setIntegerValueField(.mouseEventClickState, value: Int64(count))
                event?.post(tap: .cghidEventTap)
                await sleep(30)
            }
        }
        await sleep(320)
    }

    /// 滚轮：`units: .line` 走的是非精确增量，和真实鼠标滚轮一条路（触控板是另一条）。
    static func scroll(lines: Int32, at point: CGPoint) async {
        let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
                            wheel1: lines, wheel2: 0, wheel3: 0)
        event?.location = point
        event?.post(tap: .cghidEventTap)
        await sleep(320)
    }
}

// MARK: - 场景

@MainActor
func runPinSuite() async -> Int32 {
    let report = PinSuiteReport()

    // 临时库：不碰用户真实的贴图记录
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("baton-pin-suite-store", isDirectory: true)
    try? FileManager.default.removeItem(at: directory)
    var store: PinStore?
    if let database = try? BatonDatabase(directory: directory) {
        store = PinStore(clipboard: ClipboardStore(database: database))
    }
    report.check("P00", "测试库就绪", store != nil, "\(directory.lastPathComponent)")

    NSApp.activate(ignoringOtherApps: true)
    let pins = PinController(store: store)

    pins.pin(suiteImage(width: 1200, height: 760), scale: 2)
    await PinEvents.sleep(900)

    /// 基线：还没画任何东西时导出的图，后面用来证明标注真的烧结进去了
    pins.debugSendKey(36)
    await PinEvents.sleep(300)
    let baseline = suitePasteboardImage()
    report.check("P00b", "导出基线可取", baseline != nil,
                 baseline.map { "\($0.width)x\($0.height)" } ?? "nil")

    guard var snapshot = pins.debugSnapshot else {
        report.check("P01", "贴图已创建", false, "拿不到快照，后续全部无法验证")
        report.summary()
        return report.exitCode
    }

    // P01 新钉一张：尺寸按倍率换算、有内容、写进库
    report.check("P01", "新钉一张：尺寸/内容/落库",
                 abs(snapshot.frame.width - 600) < 1.5 && abs(snapshot.frame.height - 380) < 1.5
                    && snapshot.hasContent && snapshot.stored,
                 "frame=\(snapshot.frame.size) content=\(snapshot.hasContent) stored=\(snapshot.stored)")

    // P02 连按三次 = 会跨过显示位图的缓存档位，取不到图就只剩黑框
    for _ in 0..<3 { pins.debugSendKey(24) }
    await PinEvents.sleep(400)
    snapshot = pins.debugSnapshot!
    report.check("P02", "缩放换档位后画面不空白",
                 snapshot.hasContent && snapshot.frame.width > 620,
                 "zoom=\(String(format: "%.2f", snapshot.zoom)) w=\(Int(snapshot.frame.width)) content=\(snapshot.hasContent)")

    for _ in 0..<3 { pins.debugSendKey(27) }
    await PinEvents.sleep(400)
    snapshot = pins.debugSnapshot!
    report.check("P03", "缩放可回到初始倍率",
                 abs(snapshot.zoom - 1) < 0.01,
                 "zoom=\(String(format: "%.3f", snapshot.zoom)) content=\(snapshot.hasContent)")

    // P04 空格进标注
    pins.debugSendKey(49)
    await PinEvents.sleep(500)
    pins.debugMakeKey()
    await PinEvents.sleep(200)
    snapshot = pins.debugSnapshot!
    let middle = CGPoint(x: snapshot.frame.width / 2, y: snapshot.frame.height / 2)
    report.check("P04", "空格进入标注：工具条浮出、画布接管",
                 snapshot.editing && snapshot.barVisible && snapshot.canvasInteractive
                    && pins.debugHitIsCanvas(at: middle),
                 "editing=\(snapshot.editing) bar=\(snapshot.barVisible)"
                    + " interactive=\(snapshot.canvasInteractive) 命中画布=\(pins.debugHitIsCanvas(at: middle))")

    // P05 工具条不能盖住贴图本身，也不能跑出屏幕
    let screen = NSScreen.screens.first?.visibleFrame ?? .zero
    report.check("P05", "工具条在贴图外面且在屏内",
                 snapshot.barVisible
                    && !snapshot.barFrame.intersects(snapshot.frame)
                    && screen.contains(snapshot.barFrame),
                 "bar=\(snapshot.barFrame) pin=\(snapshot.frame)")

    // P06 标注态拖拽：窗口不动，并且真的落下一个图元
    let frameBefore = snapshot.frame
    // 画布坐标 = 图片像素，且是「左上原点」；窗口点是「左下原点」，y 要翻一次。
    // 比例尺从画布自己读，别假设正好是 2（缩放之后窗口宽不是 600）。
    let canvas = pins.debugCanvas
    let scale = canvas.map { CGFloat($0.baseImage.width) / max($0.bounds.width, 1) } ?? 2
    let pad = canvas?.style.lineWidth ?? 6
    let start = PinEvents.global(CGPoint(x: 150, y: 120), in: frameBefore)
    let end = PinEvents.global(CGPoint(x: 350, y: 240), in: frameBefore)
    await PinEvents.hover(start)
    await PinEvents.drag(from: start, to: end)
    snapshot = pins.debugSnapshot!
    let drew = snapshot.annotationRects.first
    report.check("P06", "标注态拖拽：窗口不动 + 画出图元",
                 snapshot.frame == frameBefore && snapshot.annotationRects.count == 1,
                 "frame=\(snapshot.frame.origin) 图元=\(snapshot.annotationRects.count)")
    let rawRect = CGRect(x: 150 * scale,
                         y: (frameBefore.height - 240) * scale,
                         width: 200 * scale, height: 120 * scale)
    let expectedRect = rawRect.insetBy(dx: -pad, dy: -pad)
    report.check("P06b", "图元几何与拖拽一致",
                 drew.map {
                     abs($0.minX - expectedRect.minX) < 5 && abs($0.minY - expectedRect.minY) < 5
                        && abs($0.width - expectedRect.width) < 5 && abs($0.height - expectedRect.height) < 5
                 } ?? false,
                 "rect=\(drew.map { "\(Int($0.minX)),\(Int($0.minY)) \(Int($0.width))x\(Int($0.height))" } ?? "nil")"
                    + " 期望=\(Int(expectedRect.minX)),\(Int(expectedRect.minY)) \(Int(expectedRect.width))x\(Int(expectedRect.height))"
                    + " scale=\(String(format: "%.2f", scale))")

    // P07 悬停到图元上要变抓手
    let center = CGPoint(x: 250, y: 180)   // 窗口点，正好落在图元内部
    await PinEvents.hover(PinEvents.global(center, in: frameBefore))
    report.check("P07", "悬停图元光标变抓手",
                 NSCursor.current === NSCursor.openHand,
                 "cursor=\(NSCursor.current === NSCursor.openHand ? "openHand" : "other")")

    // P08 单击选中
    await PinEvents.click(PinEvents.global(center, in: frameBefore))
    snapshot = pins.debugSnapshot!
    report.check("P08", "单击选中图元", snapshot.selectionRect != nil,
                 "selection=\(snapshot.selectionRect.map { "\(Int($0.width))x\(Int($0.height))" } ?? "nil")")

    // P09 拖右下角的手柄改几何
    let beforeResize = snapshot.annotationRects.first
    let corner = PinEvents.global(CGPoint(x: 350, y: 240), in: frameBefore)
    let cornerTo = PinEvents.global(CGPoint(x: 400, y: 270), in: frameBefore)
    await PinEvents.drag(from: corner, to: cornerTo)
    snapshot = pins.debugSnapshot!
    let resized = snapshot.annotationRects.first
    report.check("P09", "拖角柄改尺寸",
                 resized.map {
                     abs($0.width - (beforeResize?.width ?? 0) - 50 * scale) < 8
                        && abs($0.height - (beforeResize?.height ?? 0) - 30 * scale) < 8
                 } ?? false,
                 "rect=\(resized.map { "\(Int($0.width))x\(Int($0.height))" } ?? "nil")"
                    + " 之前=\(beforeResize.map { "\(Int($0.width))x\(Int($0.height))" } ?? "nil")")

    // P10 选中后方向键移图元，窗口不动
    let rectBeforeNudge = snapshot.annotationRects.first
    pins.debugSendKey(123)
    await PinEvents.sleep(200)
    snapshot = pins.debugSnapshot!
    let nudged = snapshot.annotationRects.first
    report.check("P10", "方向键移图元而不是移窗口",
                 snapshot.frame == frameBefore
                    && nudged.map { $0.minX < (rectBeforeNudge?.minX ?? 0) } ?? false,
                 "dx=\(Int((nudged?.minX ?? 0) - (rectBeforeNudge?.minX ?? 0))) frame=\(snapshot.frame.origin)")

    // P11 编辑中缩放窗口：画布跟着变大，标注的图像坐标不动
    let rectsBeforeZoom = snapshot.annotationRects
    pins.debugSendKey(24)
    await PinEvents.sleep(400)
    snapshot = pins.debugSnapshot!
    let canvasWidth = pins.debugCanvas?.bounds.width ?? 0
    report.check("P11", "标注态缩放：画布跟随、标注粘在图像上",
                 abs(canvasWidth - snapshot.frame.width) < 1.5 && snapshot.annotationRects == rectsBeforeZoom,
                 "canvas=\(Int(canvasWidth)) frame=\(Int(snapshot.frame.width)) 图元不变=\(snapshot.annotationRects == rectsBeforeZoom)")
    pins.debugSendKey(27)
    await PinEvents.sleep(400)

    // P12 撤销 / 重做（走画布的 ⌘Z，验证拦截器没把 ⌘Z 抢走）
    //
    // 栈上是三步：落笔、拖手柄、方向键微调。所以撤销两次才回到落笔时的几何，
    // 一次只是把 1px 的微调退回去，看上去没变化。
    let resizedSize = pins.debugSnapshot?.annotationRects.first
    pins.debugSendKey(6, command: true)
    pins.debugSendKey(6, command: true)
    await PinEvents.sleep(300)
    let undone = pins.debugSnapshot?.annotationRects.first
    pins.debugSendKey(6, command: true, shift: true)
    pins.debugSendKey(6, command: true, shift: true)
    await PinEvents.sleep(300)
    let redone = pins.debugSnapshot?.annotationRects.first
    report.check("P12", "⌘Z 撤销 / ⇧⌘Z 重做归画布",
                 undone.map { abs($0.width - (beforeResize?.width ?? 0)) < 3 } ?? false
                    && redone.map { abs($0.width - (resizedSize?.width ?? 0)) < 3 } ?? false,
                 "落笔=\(Int(beforeResize?.width ?? 0)) 改完=\(Int(resizedSize?.width ?? 0))"
                    + " 撤销后=\(Int(undone?.width ?? 0)) 重做后=\(Int(redone?.width ?? 0))")

    // P13 Esc：有选中先取消选中，不退标注
    pins.debugSendKey(53)
    await PinEvents.sleep(250)
    snapshot = pins.debugSnapshot!
    report.check("P13", "Esc 第一下只取消选中",
                 snapshot.selectionRect == nil && snapshot.editing,
                 "selection=\(String(describing: snapshot.selectionRect)) editing=\(snapshot.editing)")

    // P14 Esc：没有选中才退标注，窗口还在
    pins.debugSendKey(53)
    await PinEvents.sleep(300)
    snapshot = pins.debugSnapshot!
    report.check("P14", "Esc 第二下退标注、不关窗",
                 !snapshot.editing && !snapshot.barVisible && snapshot.frame != .zero
                    && !pins.debugHitIsCanvas(at: middle),
                 "editing=\(snapshot.editing) bar=\(snapshot.barVisible)"
                    + " 命中画布=\(pins.debugHitIsCanvas(at: middle))")

    // P15 退出标注后光标该是箭头（此前的 bug：一直是十字）
    //
    // 断言读画布的判定而不是 `NSCursor.current`：后台进程里 AppKit 未必真的换掉
    // 系统光标（试过，改坏了也不变），读系统光标等于给自己一个永远绿的用例。
    // 真实光标形状那条路由单测 `PinCanvasInteractivityTests` 守着。
    await PinEvents.hover(PinEvents.global(center, in: frameBefore))
    await PinEvents.hover(PinEvents.global(CGPoint(x: 260, y: 190), in: frameBefore))
    report.check("P15", "退出标注后光标判定为箭头",
                 pins.debugSnapshot?.cursorIsArrow == true,
                 "cursorIsArrow=\(pins.debugSnapshot?.cursorIsArrow ?? false)"
                    + " 系统光标=\(NSCursor.current === NSCursor.arrow ? "arrow" : "other")")

    // P16 退出标注后拖拽能搬窗口
    let beforeDrag = pins.debugSnapshot!.frame
    await PinEvents.drag(from: PinEvents.global(CGPoint(x: 250, y: 180), in: beforeDrag),
                         to: PinEvents.global(CGPoint(x: 290, y: 150), in: beforeDrag))
    let afterDrag = pins.debugSnapshot!.frame
    report.check("P16", "退出标注后拖拽搬窗口",
                 abs(afterDrag.minX - beforeDrag.minX - 40) < 1.5
                    && abs(afterDrag.minY - beforeDrag.minY + 30) < 1.5,
                 "Δ=\(Int(afterDrag.minX - beforeDrag.minX)),\(Int(afterDrag.minY - beforeDrag.minY))")

    // P17 滚轮缩放（只读态）
    let hoverPoint = PinEvents.global(CGPoint(x: 250, y: 180), in: afterDrag)
    await PinEvents.hover(hoverPoint)
    let zoomBeforeScroll = pins.debugSnapshot!.zoom
    await PinEvents.scroll(lines: 6, at: hoverPoint)
    let zoomAfterScroll = pins.debugSnapshot!.zoom
    report.check("P17", "滚轮缩放",
                 zoomAfterScroll > zoomBeforeScroll + 0.01 && pins.debugSnapshot!.hasContent,
                 "\(String(format: "%.2f", zoomBeforeScroll)) → \(String(format: "%.2f", zoomAfterScroll))")

    // P18 双击在 100% 与「适配屏幕」之间切
    pins.debugSendKey(24)          // 先放大一点，确保当前不是 100%
    pins.debugSendKey(24)
    await PinEvents.sleep(350)
    let zoomBeforeDouble = pins.debugSnapshot!.zoom
    await PinEvents.doubleClick(hoverPoint)
    let zoomAfterDouble = pins.debugSnapshot!.zoom
    report.check("P18", "双击回到 100%",
                 zoomBeforeDouble > 1.05 && abs(zoomAfterDouble - 1) < 0.02,
                 "\(String(format: "%.2f", zoomBeforeDouble)) → \(String(format: "%.2f", zoomAfterDouble))")

    // P19 R 进缩略图：长边收到 160，并且自动退出标注
    pins.debugSendKey(49)          // 先进标注
    await PinEvents.sleep(350)
    report.check("P19a", "R 之前处于标注态", pins.debugSnapshot?.editing == true)
    pins.debugSendKey(15)          // R
    await PinEvents.sleep(500)
    snapshot = pins.debugSnapshot!
    let longest = max(snapshot.frame.width, snapshot.frame.height)
    report.check("P19", "R 缩略图：长边约 160 且退标注",
                 snapshot.isThumbnail && abs(longest - 160) < 2 && !snapshot.editing,
                 "longest=\(Int(longest)) thumbnail=\(snapshot.isThumbnail) editing=\(snapshot.editing)")

    // P20 再按 R 回到原倍率
    pins.debugSendKey(15)
    await PinEvents.sleep(500)
    snapshot = pins.debugSnapshot!
    report.check("P20", "再按 R 恢复原倍率",
                 !snapshot.isThumbnail && abs(snapshot.zoom - 1) < 0.01,
                 "zoom=\(String(format: "%.3f", snapshot.zoom)) thumbnail=\(snapshot.isThumbnail)")

    // P21 导出：原图像素 + 标注真的烘进去了
    pins.debugSendKey(36)
    await PinEvents.sleep(400)
    let exported = suitePasteboardImage()
    var diff = -1
    if let baseline, let exported, baseline.width == exported.width, baseline.height == exported.height {
        diff = suitePixelDiff(baseline, exported)
    }
    report.check("P21", "复制出的是原图尺寸且带标注",
                 exported.map { $0.width == 1200 && $0.height == 760 } ?? false && diff > 1000,
                 "size=\(exported.map { "\($0.width)x\($0.height)" } ?? "nil") diff=\(diff)")

    // P22 不透明度
    let alphaBefore = pins.debugSnapshot!.alpha
    pins.debugSendKey(27, command: true)
    await PinEvents.sleep(250)
    let alphaAfter = pins.debugSnapshot!.alpha
    report.check("P22", "⌘- 降低不透明度",
                 abs(alphaAfter - (alphaBefore - 0.1)) < 0.02,
                 "\(alphaBefore) → \(alphaAfter)")

    // P23 隐藏 / 显示
    pins.setHidden(true)
    await PinEvents.sleep(250)
    let hidden = pins.isHidden
    pins.setHidden(false)
    await PinEvents.sleep(350)
    report.check("P23", "隐藏/显示所有贴图",
                 hidden && !pins.isHidden && pins.count == 1,
                 "hidden=\(hidden) count=\(pins.count)")

    // P24 关掉：子窗口和库记录一起走
    pins.debugCloseLast()
    await PinEvents.sleep(400)
    report.check("P24", "关闭后不留贴图", pins.count == 0, "count=\(pins.count)")

    // 人工项：这里明确列出来，免得被当成都验过了
    report.skip("M01", "保存面板（⌘D / ⇧⌘D）", "会弹模态面板，自动化会卡住")
    report.skip("M02", "右键菜单各项", "同上，popUp 之后要人手点")
    report.skip("M03", "从 Finder 拖图进来", "需要真实拖放会话")
    report.skip("M04", "重启后恢复上次的贴图", "要真的重启进程")
    report.skip("M05", "工具条外观/间距观感", "要人眼判断")

    report.summary()
    return report.exitCode
}

// MARK: - 小工具

/// 测试图：几条色带 + 斜线，够看清「图还在不在、标注画在哪」。
func suiteImage(width: Int = 1200, height: Int = 760) -> CGImage {
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(CGColor(srgbRed: 0.97, green: 0.97, blue: 0.98, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let colors = [CGColor(srgbRed: 0.95, green: 0.35, blue: 0.3, alpha: 1),
                  CGColor(srgbRed: 0.98, green: 0.7, blue: 0.2, alpha: 1),
                  CGColor(srgbRed: 0.25, green: 0.7, blue: 0.45, alpha: 1),
                  CGColor(srgbRed: 0.2, green: 0.5, blue: 0.95, alpha: 1)]
    for (index, color) in colors.enumerated() {
        context.setFillColor(color)
        context.fill(CGRect(x: 40, y: 40 + index * height / 5, width: width / 3, height: height / 8))
    }
    return context.makeImage()!
}

func suitePasteboardImage() -> CGImage? {
    guard let image = NSPasteboard.general.readObjects(forClasses: [NSImage.self])?.first as? NSImage else {
        return nil
    }
    var rect = CGRect(origin: .zero, size: image.size)
    return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
}

/// 两张图有多少像素不一样（尺寸不同直接算作最大差异）
func suitePixelDiff(_ a: CGImage, _ b: CGImage) -> Int {
    guard a.width == b.width, a.height == b.height else { return .max }
    let width = a.width, height = a.height
    let bytes = width * height * 4
    var left = [UInt8](repeating: 0, count: bytes)
    var right = [UInt8](repeating: 0, count: bytes)
    guard let context = CGContext(data: &left, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        return -1
    }
    context.draw(a, in: CGRect(x: 0, y: 0, width: width, height: height))
    guard let second = CGContext(data: &right, width: width, height: height, bitsPerComponent: 8,
                                 bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        return -1
    }
    second.draw(b, in: CGRect(x: 0, y: 0, width: width, height: height))
    var count = 0
    for index in stride(from: 0, to: bytes, by: 4) {
        if left[index] != right[index] || left[index + 1] != right[index + 1]
            || left[index + 2] != right[index + 2] {
            count += 1
        }
    }
    return count
}
