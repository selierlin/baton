import AppKit
import BatonCore

/// 截图态（框选 + 原地标注）的场景跑测（`Baton --capture-suite`）。
///
/// 和贴图套件同一套思路：开真窗口、发真鼠标事件（CGEvent）、断言读真状态。
/// 唯一被替换的是「抓屏」——终端里 `ScreenCaptureKit` 拿不到共享内容
/// （`--inplace-probe` 早就撞过 `noDisplays`），所以这里用一张自绘的假冻结帧
/// 铺满主屏。覆盖层、选区手柄、遮罩、原地标注走的仍然是线上那条代码路径。
///
/// 测不了 / 不在这里测的：
/// - 真实抓出来的像素对不对（那是 `ScreenCapturer` 的事，和交互无关）
/// - 保存面板、右键菜单（模态，会卡住自动化）
/// - 多屏（套件只铺主屏）

@MainActor
final class CaptureHarness {
    let overlay = OverlayController()
    let display: DisplayFrame
    let frozen: CGImage
    let pins: PinController

    private(set) var selection: CaptureSelection?
    private(set) var result: CaptureResult?
    private(set) var annotator: InPlaceAnnotator?
    private(set) var outcomes: [InPlaceAnnotator.Outcome] = []
    /// 每一场都换新的编辑器，旧的要留住引用，否则视图跟着被回收
    private var annotators: [InPlaceAnnotator] = []

    init(pins: PinController) {
        let screen = NSScreen.screens[0]
        let scale = screen.backingScaleFactor
        let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
        display = DisplayFrame(displayID: number?.uint32Value ?? CGMainDisplayID(),
                               screenFrame: screen.frame,
                               pixelSize: CGSize(width: screen.frame.width * scale,
                                                 height: screen.frame.height * scale),
                               nativeScale: scale)
        frozen = suiteImage(width: Int(display.pixelSize.width),
                            height: Int(display.pixelSize.height))
        self.pins = pins
    }

    /// 拉起覆盖层 → 拖出选区 → 把原地编辑器挂上去。
    func startSession(from: CGPoint, to: CGPoint) async -> Bool {
        let task = Task { [overlay, frozen, display] in
            await overlay.select(from: [CapturedFrame(image: frozen, display: display)],
                                 keepsSelection: true)
        }
        await ScenarioEvents.sleep(600)
        await ScenarioEvents.drag(from: from, to: to)
        guard let selection = await task.value else { return false }

        let result = CaptureResult(image: frozen,
                                   pixelRect: CaptureGeometry.pixelRect(forGlobal: selection.globalRect,
                                                                        in: display),
                                   screenRect: selection.globalRect,
                                   display: display,
                                   action: .edit)
        let annotator = InPlaceAnnotator(pinController: pins)
        annotator.onFinish = { [weak self] in self?.outcomes.append($0) }
        guard annotator.present(result: result, overlay: overlay) else { return false }

        self.selection = selection
        self.result = result
        self.annotator = annotator
        annotators.append(annotator)
        await ScenarioEvents.sleep(350)
        return true
    }

    /// 只拉起覆盖层，不框选：验框选阶段的键位。
    func openOverlay() async -> Task<CaptureSelection?, Never> {
        let task = Task { [overlay, frozen, display] in
            await overlay.select(from: [CapturedFrame(image: frozen, display: display)],
                                 keepsSelection: true)
        }
        await ScenarioEvents.sleep(600)
        return task
    }

    var snapshot: InPlaceAnnotator.Snapshot {
        annotator?.debugSnapshot ?? InPlaceAnnotator.Snapshot()
    }
}

@MainActor
func runCaptureSuite() async -> Int32 {
    let report = ScenarioReport()
    NSApp.activate(ignoringOtherApps: true)

    guard NSScreen.screens.first != nil else {
        report.check("C00", "主屏可用", false, "没有屏幕")
        report.summary()
        return report.exitCode
    }

    let pins = PinController()
    let harness = CaptureHarness(pins: pins)
    let display = harness.display
    let screen = display.screenFrame
    // 框选范围避开菜单栏和 Dock：用可见区域，坐标转成左上原点
    let visible = NSScreen.screens[0].visibleFrame
    let usable = CGRect(x: visible.minX,
                        y: screen.height - visible.maxY,
                        width: visible.width,
                        height: visible.height)

    // MARK: 第一场：框选 → 挂编辑器 → 手柄/键盘改选区 → 落笔 → 撤销

    let a0 = CGPoint(x: (usable.minX + usable.width * 0.22).rounded(),
                     y: (usable.minY + usable.height * 0.26).rounded())
    let a1 = CGPoint(x: (usable.minX + usable.width * 0.62).rounded(),
                     y: (usable.minY + usable.height * 0.68).rounded())
    let expected = CGRect(x: a0.x, y: a0.y, width: a1.x - a0.x, height: a1.y - a0.y)

    let started = await harness.startSession(from: a0, to: a1)
    report.check("C00", "覆盖层与编辑器就绪", started,
                 started ? "选区=\(harness.selection?.globalRect ?? .zero)" : "选区没交回来")
    guard started, var snapshot = harness.annotator?.debugSnapshot else {
        harness.overlay.dismiss()
        report.summary()
        return report.exitCode
    }

    // C01 框选尺寸：拖到哪就是哪（差 2pt 内）
    report.check("C01", "拖框尺寸与轨迹一致",closeEnough(snapshot.selectionGlobal, expected, 2),
                 "选区=\(snapshot.selectionGlobal.shortText) 期望=\(expected.shortText)")

    // C02 画布对齐选区：画布 frame 必须正好落在覆盖层给的那块矩形上
    let local = harness.overlay.localRect(forGlobal: snapshot.selectionGlobal,
                                          displayID: display.displayID) ?? .zero
    report.check("C02", "画布与选区严丝合缝",closeEnough(snapshot.canvasFrame, local, 1.5),
                 "canvas=\(snapshot.canvasFrame.shortText) local=\(local.shortText)")

    // C03 工具条：在选区外、在屏内
    report.check("C03", "工具条浮在选区外且在屏内",
                 snapshot.barVisible
                    && !snapshot.barFrame.intersects(snapshot.canvasFrame)
                    && snapshot.hostBounds.contains(snapshot.barFrame),
                 "bar=\(snapshot.barFrame.shortText) canvas=\(snapshot.canvasFrame.shortText)")

    // C04 8 个手柄的图层挂上了
    report.check("C04", "8 个选区手柄可见", snapshot.handlesVisible)

    // C05 从画布外 6pt 抓右下角：手柄中心压在边界上，朝外那半边没有视图，
    //     要靠覆盖层的 hitTest 转回画布（贴图里修过的同一个坑）
    let cornerStart = CGPoint(x: snapshot.selectionGlobal.maxX + 6,
                              y: snapshot.selectionGlobal.maxY + 6)
    let cornerEnd = CGPoint(x: cornerStart.x + 40, y: cornerStart.y + 30)
    await ScenarioEvents.drag(from: cornerStart, to: cornerEnd)
    snapshot = harness.snapshot
    let afterCorner = snapshot.selectionGlobal
    // 手柄被抓住之后，那个角就跟着指针走：终点在原始右下角外 46/36，
    // 所以新选区也应该是 46/36，而不是 40/30
    report.check("C05", "画布外的角落手柄能拖",
                 abs(afterCorner.maxX - cornerEnd.x) < 3
                    && abs(afterCorner.maxY - cornerEnd.y) < 3
                    && abs(afterCorner.minX - expected.minX) < 2
                    && abs(afterCorner.minY - expected.minY) < 2,
                 "选区=\(afterCorner.shortText) 指针=\(Int(cornerEnd.x)),\(Int(cornerEnd.y))")

    // C06 遮罩/边框跟着选区：宿主锁定值必须和画布认为的一致
    report.check("C06", "遮罩与画布同步换选区",
                 closeEnough(harness.overlay.debugLockedSelection ?? .zero, afterCorner, 1.5),
                 "locked=\(String(describing: harness.overlay.debugLockedSelection))")

    // C07 ⌘→ 扩 5pt、⇧→ 缩 5pt：回到原尺寸
    let beforeKey = harness.snapshot.selectionGlobal
    for _ in 0..<5 { harness.annotator?.debugSendKey(124, command: true) }
    let expanded = harness.snapshot.selectionGlobal
    for _ in 0..<5 { harness.annotator?.debugSendKey(124, shift: true) }
    let shrunk = harness.snapshot.selectionGlobal
    report.check("C07", "⌘→ 扩 / ⇧→ 缩 各 1pt",
                 abs(expanded.width - beforeKey.width - 5) < 1.5
                    && abs(shrunk.width - beforeKey.width) < 1.5,
                 "起点=\(Int(beforeKey.width)) 扩后=\(Int(expanded.width)) 缩回=\(Int(shrunk.width))")

    // C08 ← 移整个选区：画布 frame 也要跟着走
    let beforeMove = harness.snapshot
    for _ in 0..<10 { harness.annotator?.debugSendKey(123) }
    let moved = harness.snapshot
    report.check("C08", "方向键移选区、画布跟随",
                 abs(moved.selectionGlobal.minX - beforeMove.selectionGlobal.minX + 10) < 1.5
                    && abs(moved.canvasFrame.minX - beforeMove.canvasFrame.minX + 10) < 1.5
                    && abs(moved.selectionGlobal.width - beforeMove.selectionGlobal.width) < 0.5,
                 "Δ选区x=\(Int(moved.selectionGlobal.minX - beforeMove.selectionGlobal.minX))"
                    + " Δ画布x=\(Int(moved.canvasFrame.minX - beforeMove.canvasFrame.minX))")

    // C09 按两下 2：直线组里轮到「平箭头」
    harness.annotator?.debugSendKey(19)
    harness.annotator?.debugSendKey(19)
    report.check("C09", "连按 2 切到平箭头", harness.snapshot.tool == "flatArrow",
                 "tool=\(harness.snapshot.tool)")

    // C10 落一笔箭头
    snapshot = harness.snapshot
    let s0 = snapshot.selectionGlobal
    let d0 = CGPoint(x: (s0.minX + s0.width * 0.28).rounded(),
                     y: (s0.minY + s0.height * 0.30).rounded())
    let d1 = CGPoint(x: (s0.minX + s0.width * 0.72).rounded(),
                     y: (s0.minY + s0.height * 0.62).rounded())
    await ScenarioEvents.drag(from: d0, to: d1)
    snapshot = harness.snapshot
    report.check("C10", "拖拽落下图元",
                 snapshot.annotationRects.count == 1
                    && (snapshot.annotationRects.first?.width ?? 0) > 0,
                 "图元=\(snapshot.annotationRects.count) rect=\(snapshot.annotationRects.first?.shortText ?? "-")")
    let arrowScreen = snapshot.annotationScreenRects.first ?? .zero

    // C11 扩左上：裁剪原点左移/上移，图元在屏幕上必须纹丝不动
    let pixelBefore = snapshot.pixelOrigin
    for _ in 0..<20 { harness.annotator?.debugSendKey(123, command: true) }
    for _ in 0..<20 { harness.annotator?.debugSendKey(126, command: true) }
    snapshot = harness.snapshot
    let arrowAfter = snapshot.annotationScreenRects.first ?? .zero
    report.check("C11", "扩左上后图元仍贴在画面上",closeEnough(arrowAfter, arrowScreen, 1.5),
                 "前=\(arrowScreen.shortText) 后=\(arrowAfter.shortText)")

    // C12 证明 C11 不是空过：裁剪原点确实挪了 40px（20pt × 2）
    report.check("C12", "裁剪原点确实左移上移",
                 abs(snapshot.pixelOrigin.x - pixelBefore.x + 40) < 2
                    && abs(snapshot.pixelOrigin.y - pixelBefore.y + 40) < 2,
                 "Δ=\(Int(snapshot.pixelOrigin.x - pixelBefore.x)),\(Int(snapshot.pixelOrigin.y - pixelBefore.y))")

    // C13 换完选区再落笔：新图元的屏幕位置要等于鼠标轨迹
    harness.annotator?.debugSendKey(18)          // 1 → 矩形
    let s1 = harness.snapshot.selectionGlobal
    let r0 = CGPoint(x: (s1.minX + s1.width * 0.20).rounded(),
                     y: (s1.minY + s1.height * 0.55).rounded())
    let r1 = CGPoint(x: (s1.minX + s1.width * 0.55).rounded(),
                     y: (s1.minY + s1.height * 0.80).rounded())
    await ScenarioEvents.drag(from: r0, to: r1)
    snapshot = harness.snapshot
    let boundsScreen = snapshot.annotationScreenRects.last ?? .zero
    // bounds 按线宽外扩了一圈（矩形是 ±lineWidth），剥掉它才是鼠标画出来的那块
    let pad = snapshot.lineWidth / max(snapshot.scale, 1)
    let rectScreen = boundsScreen.insetBy(dx: pad, dy: pad)
    let dragged = CGRect(x: r0.x, y: r0.y, width: r1.x - r0.x, height: r1.y - r0.y)
    report.check("C13", "改过选区后落笔位置仍然准",
                 snapshot.annotationRects.count == 2 && closeEnough(rectScreen, dragged, 3),
                 "图元=\(rectScreen.shortText) 轨迹=\(dragged.shortText) pad=\(String(format: "%.1f", pad))")

    // C14 v 选择工具收起属性条，1 回来
    harness.annotator?.debugSendKey(9)           // v
    let selectState = harness.snapshot
    harness.annotator?.debugSendKey(18)          // 1
    let drawState = harness.snapshot
    report.check("C14", "切到选择工具时收起属性条",
                 selectState.tool == "select" && !selectState.propertiesVisible
                    && drawState.tool == "rectangle" && drawState.propertiesVisible,
                 "select: tool=\(selectState.tool) 属性条=\(selectState.propertiesVisible)"
                    + " / rect: tool=\(drawState.tool) 属性条=\(drawState.propertiesVisible)")

    // C15 ⌘Z / ⇧⌘Z
    let countBeforeUndo = harness.snapshot.annotationRects.count
    harness.annotator?.debugSendKey(6, command: true)
    await ScenarioEvents.sleep(150)
    let afterUndo = harness.snapshot.annotationRects.count
    harness.annotator?.debugSendKey(6, command: true, shift: true)
    await ScenarioEvents.sleep(150)
    let afterRedo = harness.snapshot.annotationRects.count
    report.check("C15", "⌘Z 撤销 / ⇧⌘Z 重做",
                 afterUndo == countBeforeUndo - 1 && afterRedo == countBeforeUndo,
                 "\(countBeforeUndo) → \(afterUndo) → \(afterRedo)")

    // C16 单击选中，Esc 只取消选中
    await ScenarioEvents.click(CGPoint(x: rectScreen.midX, y: rectScreen.midY))
    snapshot = harness.snapshot
    let selected = snapshot.selectionRect != nil
    harness.annotator?.debugSendKey(53)
    await ScenarioEvents.sleep(200)
    let afterFirstEsc = harness.snapshot
    report.check("C16", "单击选中 + Esc 只取消选中",
                 selected && afterFirstEsc.selectionRect == nil && afterFirstEsc.active,
                 "选中=\(selected) Esc后选中=\(String(describing: afterFirstEsc.selectionRect)) 仍在编辑=\(afterFirstEsc.active)")

    // C17 Esc 第二下：退出整场截图，覆盖层收掉
    harness.annotator?.debugSendKey(53)
    await ScenarioEvents.sleep(400)
    var cancelled = false
    if case .cancelled = harness.outcomes.last { cancelled = true }
    report.check("C17", "Esc 第二下退截图",
                 cancelled && !harness.overlay.debugOverlayVisible && !harness.snapshot.active,
                 "结果=\(String(describing: harness.outcomes.last)) 覆盖层=\(harness.overlay.debugOverlayVisible)")

    // MARK: 第二场：↩ 复制（原图像素 + 标注真的烘进去）

    await ScenarioEvents.sleep(300)
    let b0 = CGPoint(x: (usable.minX + usable.width * 0.30).rounded(),
                     y: (usable.minY + usable.height * 0.30).rounded())
    let b1 = CGPoint(x: (usable.minX + usable.width * 0.60).rounded(),
                     y: (usable.minY + usable.height * 0.62).rounded())
    let copySession = await harness.startSession(from: b0, to: b1)
    if copySession, let baseline = harness.result?.cropped {
        let s = harness.snapshot.selectionGlobal
        await ScenarioEvents.drag(from: CGPoint(x: s.minX + s.width * 0.25, y: s.minY + s.height * 0.25),
                                  to: CGPoint(x: s.minX + s.width * 0.75, y: s.minY + s.height * 0.70))
        NSPasteboard.general.clearContents()
        harness.annotator?.debugSendKey(36)       // ↩
        await ScenarioEvents.sleep(600)
        let exported = suitePasteboardImage()
        let expectedPixels = harness.result?.pixelRect ?? .zero
        let diff = exported.map { suitePixelDiff(baseline, $0) } ?? -1
        report.check("C18", "↩ 复制：原图尺寸 + 标注已烘进去",
                     exported.map { abs(CGFloat($0.width) - expectedPixels.width) < 2
                                    && abs(CGFloat($0.height) - expectedPixels.height) < 2 } ?? false
                        && diff > 1000,
                     "size=\(exported.map { "\($0.width)x\($0.height)" } ?? "nil")"
                        + " 期望=\(Int(expectedPixels.width))x\(Int(expectedPixels.height)) diff=\(diff)")
    } else {
        report.check("C18", "↩ 复制：原图尺寸 + 标注已烘进去", false, "第二场没起来")
    }
    await ScenarioEvents.sleep(300)

    // MARK: 第三场：P 贴图

    let c0 = CGPoint(x: (usable.minX + usable.width * 0.35).rounded(),
                     y: (usable.minY + usable.height * 0.35).rounded())
    let c1 = CGPoint(x: (usable.minX + usable.width * 0.58).rounded(),
                     y: (usable.minY + usable.height * 0.58).rounded())
    let pinSession = await harness.startSession(from: c0, to: c1)
    if pinSession {
        harness.annotator?.debugSendKey(35)       // p
        await ScenarioEvents.sleep(700)
        var pinned = false
        if case .pinned = harness.outcomes.last { pinned = true }
        report.check("C19", "标完后 P 贴图",
                     pinned && pins.count == 1 && !harness.overlay.debugOverlayVisible,
                     "结果=\(String(describing: harness.outcomes.last)) 贴图=\(pins.count)")
    } else {
        report.check("C19", "标完后 P 贴图", false, "第三场没起来")
    }
    pins.debugCloseAll()
    await ScenarioEvents.sleep(300)

    // MARK: 第四场：改完选区再复制，导出要按新选区重裁

    let f0 = CGPoint(x: (usable.minX + usable.width * 0.28).rounded(),
                     y: (usable.minY + usable.height * 0.28).rounded())
    let f1 = CGPoint(x: (usable.minX + usable.width * 0.52).rounded(),
                     y: (usable.minY + usable.height * 0.50).rounded())
    let recropSession = await harness.startSession(from: f0, to: f1)
    if recropSession {
        for _ in 0..<30 { harness.annotator?.debugSendKey(124, command: true) }
        for _ in 0..<20 { harness.annotator?.debugSendKey(125, command: true) }
        await ScenarioEvents.sleep(300)
        let grown = harness.snapshot.selectionGlobal
        NSPasteboard.general.clearContents()
        harness.annotator?.debugSendKey(36)
        await ScenarioEvents.sleep(600)
        let exported = suitePasteboardImage()
        let expectedWidth = Int((grown.width * display.captureScale.width).rounded())
        let expectedHeight = Int((grown.height * display.captureScale.height).rounded())
        report.check("C22", "改完选区再复制，按新选区重裁",
                     exported.map { abs($0.width - expectedWidth) < 4
                                    && abs($0.height - expectedHeight) < 4 } ?? false,
                     "size=\(exported.map { "\($0.width)x\($0.height)" } ?? "nil")"
                        + " 期望≈\(expectedWidth)x\(expectedHeight) 选区=\(grown.shortText)")
    } else {
        report.check("C22", "改完选区再复制，按新选区重裁", false, "第四场没起来")
    }
    await ScenarioEvents.sleep(300)

    // MARK: 第五场：选区贴底时工具条翻到上方

    let bottomY = usable.maxY - 40
    let e0 = CGPoint(x: (usable.minX + usable.width * 0.30).rounded(), y: bottomY - 220)
    let e1 = CGPoint(x: (usable.minX + usable.width * 0.66).rounded(), y: bottomY)
    let bottomSession = await harness.startSession(from: e0, to: e1)
    if bottomSession {
        let s = harness.snapshot
        report.check("C20", "选区贴底时工具条翻到上方",
                     s.barVisible && s.barFrame.minY > s.canvasFrame.maxY
                        && s.hostBounds.contains(s.barFrame),
                     "bar.minY=\(Int(s.barFrame.minY)) canvas.maxY=\(Int(s.canvasFrame.maxY))")
        harness.annotator?.debugSendKey(53)
        await ScenarioEvents.sleep(400)
    } else {
        report.check("C20", "选区贴底时工具条翻到上方", false, "第四场没起来")
    }

    // MARK: 第六场：框选阶段 Esc 直接退出（还没框就按）

    let frameOnly = await harness.openOverlay()
    let ready = harness.overlay.debugOverlayVisible
    harness.overlay.debugSendKey(53)
    let none = await frameOnly.value
    await ScenarioEvents.sleep(300)
    report.check("C21", "框选阶段 Esc 直接退出",
                 ready && none == nil && !harness.overlay.debugOverlayVisible,
                 "就绪=\(ready) 结果=\(none == nil ? "nil" : "有选区")")

    harness.overlay.dismiss()

    report.skip("M01", "保存面板（⌘D / ⇧⌘D）", "会弹模态面板，自动化会卡住")
    report.skip("M02", "右键菜单各项", "同上，popUp 之后要人手点")
    report.skip("M03", "真实抓屏的像素内容", "终端里 SCK 拿不到共享内容，套件用假冻结帧")
    report.skip("M04", "多屏框选", "套件只铺主屏")
    report.skip("M05", "放大镜 / 提示条观感", "要人眼判断")

    report.summary()
    return report.exitCode
}

// MARK: - 小工具

private func closeEnough(_ a: CGRect, _ b: CGRect, _ tolerance: CGFloat) -> Bool {
    abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
        && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
}

extension CGRect {
    /// 日志里一行放下，别让 `(1.0, 2.0, 3.0, 4.0)` 那种格式撑满屏
    var shortText: String {
        "\(Int(minX)),\(Int(minY)) \(Int(width))x\(Int(height))"
    }
}
