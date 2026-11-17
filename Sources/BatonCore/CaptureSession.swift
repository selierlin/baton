import AppKit
import CoreGraphics
import Foundation
import os

/// 进入方式：决定 overlay 的初始形态。
public enum CaptureIntent: Sendable, Equatable {
    case area
    case window
    case element
    /// `displayID` 为 nil 时取鼠标所在的那块屏。
    case fullScreen(displayID: CGDirectDisplayID?)
    case lastArea
    /// 直接抓指定窗口，不铺覆盖层（「截取活动窗口」走这条）。
    case windowID(Int)
    /// 外部指定区域（长截图取帧、贴图取源也走这条）
    case fixed(CGRect)
}

/// 框后动作：可以后选，也可以由热键预设。
public enum CaptureAction: Sendable, Equatable {
    case copy
    case save(format: ImageFormat)
    case edit
    case pin
    case ocr(silent: Bool)
    case translate
    case scroll(direction: ScrollDirection)
    case pickColor
    case ruler
}

public enum ImageFormat: String, Sendable { case png, jpeg, heic }
public enum ScrollDirection: String, Sendable { case vertical, horizontal }

public struct CaptureResult: Sendable {
    public let image: CGImage
    /// 原图内的像素矩形（左上原点）
    public let pixelRect: CGRect
    /// 全局显示坐标（点，左上原点）
    public let screenRect: CGRect
    public let display: DisplayFrame
    public let action: CaptureAction

    public init(image: CGImage, pixelRect: CGRect, screenRect: CGRect,
                display: DisplayFrame, action: CaptureAction) {
        self.image = image
        self.pixelRect = pixelRect
        self.screenRect = screenRect
        self.display = display
        self.action = action
    }

    /// 裁剪出选区。`CGImage.cropping(to:)` 是零拷贝的视图，不会多一份位图。
    public var cropped: CGImage? {
        image.cropping(to: pixelRect.integral)
    }
}

public enum CaptureOutcome: Sendable {
    case cancelled
    case captured(CaptureResult)
    case failed(String)
}

@MainActor
public final class CaptureSession {
    private let log = Logger(subsystem: "com.selier.baton", category: "capture")
    private let overlay: OverlayController
    private let picker = PickService()
    private let settings: CaptureSettingsStore

    /// 抓帧时要留在画面里的贴图窗口号，AppShell 每次进截图前刷新。
    ///
    /// 空集 = 自己的窗口全排除（覆盖层、HUD、设置窗都不进图），和以前一致；
    /// 填了贴图窗口就把它们留下来——按截图时贴图当场消失是说不通的。
    public var pinWindowIDs: Set<CGWindowID> = []

    public init(overlay: OverlayController = OverlayController(),
                settings: CaptureSettingsStore = CaptureSettingsStore()) {
        self.overlay = overlay
        self.settings = settings
    }

    /// 原地标注/长截图要在框选结束后继续使用覆盖层。
    public var overlayController: OverlayController { overlay }

    /// 只要区域、不要成品：录制入口用这条。
    ///
    /// 和 `.area` 截图走同一个覆盖层，但框完就撤——录制时屏幕必须回到实时状态，
    /// 冻结帧留着的话用户看到的永远是那一帧静止画面。
    public func selectRegion() async -> CaptureSelection? {
        let frames: [CapturedFrame]
        do {
            frames = try await ScreenCapturer.captureAll(keepingPins: pinWindowIDs)
        } catch {
            log.error("录制选区抓帧失败：\(error.localizedDescription, privacy: .public)")
            return nil
        }
        return await overlay.select(from: frames)
    }

    /// 点一个窗口，拿到它的 windowID。窗口录制用。
    public func selectWindow() async -> Int? {
        let frames: [CapturedFrame]
        do {
            frames = try await ScreenCapturer.captureAll(keepingPins: pinWindowIDs)
        } catch {
            log.error("窗口录制抓帧失败：\(error.localizedDescription, privacy: .public)")
            return nil
        }
        picker.invalidate()
        let selection = await overlay.select(from: frames, mode: .pick) { [picker] point, display, _ in
            picker.probe(kind: .window, at: point, in: display)
        }
        return selection?.windowID
    }

    public func begin(intent: CaptureIntent, action: CaptureAction) async -> CaptureOutcome {
        switch PermissionCenter.status(.screenRecording) {
        case .granted:
            break
        case .denied:
            PermissionCenter.request(.screenRecording)
            return .failed("缺少屏幕录制权限")
        }

        // 元素拾取走 AX，需要在抓帧之前就拦下来，不要把冻结帧白抓一遍
        if intent == .element, PermissionCenter.status(.accessibility) == .denied {
            PermissionCenter.request(.accessibility)
            return .failed("元素拾取需要「辅助功能」权限")
        }

        // 延迟截图的倒计时放在 AppShell 层做：那边能显示倒计时面板、能取消，
        // 到这里就只剩「抓帧」一件事。
        // 抓帧的同时预热 OCR 子进程：省掉第一次识别的进程启动，免得用户感觉「截图完卡一下」
        switch action {
        case .ocr, .translate:
            SubprocessOCRTransport.warmUp()
        default:
            break
        }

        let frames: [CapturedFrame]
        // 指定窗口：一条捷径，不需要冻结帧也不需要覆盖层——
        // 「截取活动窗口」按一下就出图，不该为了框一次而把整屏合成一遍。
        if case .windowID(let windowID) = intent {
            do {
                return .captured(try await captureWindow(windowID: windowID, action: action))
            } catch CaptureFailure.screenRecordingDenied {
                return .failed("缺少屏幕录制权限")
            } catch {
                return .failed("窗口抓取失败：\(error.localizedDescription)")
            }
        }

        // 先立窗、后抓帧：窗口用的是 `NSScreen` 当场就有的几何，图没到之前窗口全透明，
        // 屏幕上看起来还是原样。以前是先抓完才建窗，那几十毫秒里屏幕上什么都不动，
        // 用户已经开始拖了 —— 拖拽落在别的 App 上，框完等于没框。
        let presentation = makePresentation(intent: intent, action: action)
        if let presentation, case .fixed(let rect) = intent,
           action == .edit,
           let display = CaptureGeometry.display(containing: CGPoint(x: rect.midX, y: rect.midY),
                                                 in: ScreenCapturer.displays()) {
            overlay.present(displays: [display],
                            mode: presentation.mode,
                            probe: presentation.probe,
                            keepsSelection: presentation.keeps,
                            initialSelection: CaptureSelection(globalRect: rect, display: display))
        } else if let presentation {
            overlay.present(displays: ScreenCapturer.displays(),
                            mode: presentation.mode,
                            probe: presentation.probe,
                            keepsSelection: presentation.keeps)
        }

        let capturedAt = Date()
        do {
            frames = try await ScreenCapturer.captureAll(keepingPins: pinWindowIDs)
        } catch CaptureFailure.screenRecordingDenied {
            overlay.dismiss()
            return .failed("缺少屏幕录制权限")
        } catch {
            overlay.dismiss()
            return .failed(String(describing: error))
        }
        // 诊断用：人为把抓帧拖慢，验证「热键按下就开拖」的接管路径
        if let delay = ProcessInfo.processInfo.environment["BATON_SLOW_CAPTURE_MS"].flatMap(Int.init),
           delay > 0 {
            try? await Task.sleep(for: .milliseconds(delay))
        }
        // 抓帧耗时 = 「按了热键，屏幕上却什么都没变」的那段空白，多屏时尤其明显
        ActionLog.action("capture.frames",
                         "ms=\(Int(Date().timeIntervalSince(capturedAt) * 1000)) displays=\(frames.count)")
        // 冻结帧到位：上屏 + 压暗
        overlay.fill(frames)

        // 长截图：框选阶段还需要冻结帧当画面，框完立刻切到实时采集
        if case .scroll(let direction) = action {
            guard direction == .vertical else {
                overlay.dismiss()
                return .failed("长截图暂只支持纵向")
            }
            let selection = await overlay.awaitSelection()
            guard let selection,
                  let frame = frames.first(where: {
                      $0.display.displayID == selection.display.displayID
                  }) else {
                return .cancelled
            }
            let pixelRect = CaptureGeometry.pixelRect(forGlobal: selection.globalRect,
                                                      in: frame.display)
            settings.remember(rect: selection.globalRect, displayID: frame.display.displayID)
            return .captured(CaptureResult(image: frame.image,
                                           pixelRect: pixelRect,
                                           screenRect: selection.globalRect,
                                           display: frame.display,
                                           action: action))
        }

        let selection: CaptureSelection?
        switch intent {
        case .fullScreen(let displayID):
            let frame: CapturedFrame
            if let displayID {
                guard let target = frames.first(where: { $0.display.displayID == displayID }) else {
                    return .failed("指定的屏幕已断开")
                }
                frame = target
            } else {
                // 多屏时不问「哪块屏」——按热键时鼠标就在目标屏上，直接取它
                frame = Self.frameUnderMouse(in: frames) ?? frames[0]
            }
            selection = CaptureSelection(globalRect: frame.display.screenFrame, display: frame.display)
        case .fixed(let rect):
            guard let frame = CaptureGeometry.display(containing: CGPoint(x: rect.midX, y: rect.midY),
                                                      in: frames.map(\.display)) else {
                overlay.dismiss()
                return .failed("指定区域不在任何屏幕上")
            }
            if action == .edit {
                // 固定区域也要有覆盖层当舞台，否则原地编辑没地方挂；
                // 上面已经带着选区立好窗了，这里只是等它交回来
                selection = await overlay.awaitSelection()
            } else {
                selection = CaptureSelection(globalRect: rect, display: frame)
            }
        case .lastArea:
            guard let last = settings.settings.lastArea else {
                return .failed("还没有可复用的区域，先框选一次")
            }
            guard let frame = frames.first(where: { $0.display.displayID == last.displayID }) else {
                return .failed("上一次区域所在的屏幕已断开")
            }
            guard last.isUsable(on: frame.display.screenFrame) else {
                return .failed("上一次区域已不在屏幕内（分辨率可能变了）")
            }
            selection = CaptureSelection(globalRect: last.rect, display: frame.display)
        case .area, .window, .element:
            selection = await overlay.awaitSelection()
        case .windowID:
            // 指定窗口在上面就走快捷路径返回了，走到这里说明状态不对
            return .failed("窗口抓取未完成")
        }

        guard let selection else { return .cancelled }

        // 悬停命中的是整窗：按窗口真实抓一次。冻结帧里那块可能正被别的窗口压着。
        if let windowID = selection.windowID {
            do {
                let shot = try await captureWindow(windowID: windowID, action: action)
                settings.remember(rect: selection.globalRect, displayID: selection.display.displayID)
                return .captured(shot)
            } catch {
                // 窗口在这一瞬间被关掉/最小化，或者 screencapture 没拿到权限：
                // 退回冻结帧里那块，至少还能出图（代价是遮挡物会被一起截进去）
                log.error("按窗口抓取失败，退回冻结帧裁剪：\(error.localizedDescription, privacy: .public)")
            }
        }

        guard let frame = frames.first(where: { $0.display.displayID == selection.display.displayID }) else {
            return .failed("选区对应的屏幕已失效")
        }

        let pixelRect = CaptureGeometry.pixelRect(forGlobal: selection.globalRect,
                                                  in: frame.display)
        settings.remember(rect: selection.globalRect, displayID: frame.display.displayID)

        return .captured(CaptureResult(image: frame.image,
                                       pixelRect: pixelRect,
                                       screenRect: selection.globalRect,
                                       display: frame.display,
                                       action: action))
    }

    /// 覆盖层的形态：拖框 / 拾取 / 固定区域当舞台。nil = 这条路径根本不铺覆盖层。
    ///
    /// 拾取粒度由覆盖层传下来：`.area` 下 ⇥ 可以在「元素/窗口区域」和「整窗」之间切。
    /// 长截图例外——滚动会话要的是精确的滚动区域，悬停高亮只会干扰判读。
    private func makePresentation(intent: CaptureIntent, action: CaptureAction)
        -> (mode: OverlayMode, probe: PickProbe?, keeps: Bool)? {
        switch intent {
        case .area:
            picker.invalidate()
            var isScroll = false
            if case .scroll = action { isScroll = true }
            let probe: PickProbe?
            if isScroll {
                probe = nil
            } else {
                probe = { [picker] point, display, kind in
                    picker.probe(kind: kind, at: point, in: display)
                }
            }
            // 标注 / 长截图不关覆盖层：框完直接在原地接着用
            return (.area, probe, action == .edit || isScroll)
        case .window:
            picker.invalidate()
            return (.pick, { [picker] point, display, _ in
                picker.probe(kind: .window, at: point, in: display)
            }, false)
        case .element:
            picker.invalidate()
            return (.pick, { [picker] point, display, _ in
                picker.probe(kind: .element, at: point, in: display)
            }, false)
        case .fixed:
            return action == .edit ? (.area, nil, true) : nil
        case .fullScreen, .lastArea, .windowID:
            return nil
        }
    }

    /// 按 windowID 抓窗口，包装成 `CaptureResult`。
    ///
    /// `pixelRect` 就是整张位图，`screenRect` 用 SCK 给的窗口矩形：下游算倍率走
    /// 「像素宽 ÷ screenRect 宽」，窗口跨屏时也不会被逐屏裁剪带偏。
    private func captureWindow(windowID: Int, action: CaptureAction) async throws -> CaptureResult {
        let shot = try await ScreenCapturer.captureWindow(windowID: windowID)
        let scale = CGFloat(shot.image.width) / max(shot.frame.width, 1)
        let display = DisplayFrame(displayID: Self.displayID(containing: shot.frame),
                                   screenFrame: shot.frame,
                                   pixelSize: CGSize(width: shot.image.width, height: shot.image.height),
                                   nativeScale: scale)
        return CaptureResult(image: shot.image,
                             pixelRect: CGRect(x: 0, y: 0,
                                               width: shot.image.width,
                                               height: shot.image.height),
                             screenRect: shot.frame,
                             display: display,
                             action: action)
    }

    /// 窗口中心落在哪块屏。窗口跨屏时只用来挑一个 ID（标注/贴图都不依赖它）。
    private static func displayID(containing rect: CGRect) -> CGDirectDisplayID {
        var id = CGDirectDisplayID(0)
        var count: UInt32 = 0
        let probe = CGRect(x: rect.midX, y: rect.midY, width: 1, height: 1)
        if CGGetDisplaysWithRect(probe, 1, &id, &count) == .success, count > 0 {
            return id
        }
        return CGMainDisplayID()
    }

    /// 鼠标所在的屏幕；找不到就返回 nil，由调用方退回第一块屏。
    private static func frameUnderMouse(in frames: [CapturedFrame]) -> CapturedFrame? {
        let mouse = NSEvent.mouseLocation   // Cocoa 全局坐标（左下原点）
        for screen in NSScreen.screens where screen.frame.contains(mouse) {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                as? NSNumber else { continue }
            if let frame = frames.first(where: { $0.display.displayID == number.uint32Value }) {
                return frame
            }
        }
        return nil
    }
}
