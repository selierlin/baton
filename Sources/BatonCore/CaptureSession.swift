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
            frames = try await ScreenCapturer.captureAll()
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
            frames = try await ScreenCapturer.captureAll()
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

        do {
            frames = try await ScreenCapturer.captureAll()
        } catch CaptureFailure.screenRecordingDenied {
            return .failed("缺少屏幕录制权限")
        } catch {
            return .failed(String(describing: error))
        }

        // 长截图：框选阶段还需要冻结帧当画面，框完立刻切到实时采集
        if case .scroll(let direction) = action {
            guard direction == .vertical else {
                return .failed("长截图暂只支持纵向")
            }
            let selection = await overlay.select(from: frames, keepsSelection: true)
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
                return .failed("指定区域不在任何屏幕上")
            }
            if action == .edit {
                // 固定区域也要有覆盖层当舞台，否则原地编辑没地方挂
                selection = await overlay.select(from: frames,
                                                 keepsSelection: true,
                                                 initialSelection: CaptureSelection(globalRect: rect,
                                                                                    display: frame))
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
        case .area:
            // Longshot 的「开始截图」不是纯拖框：鼠标停在窗口/元素上就自动框出来，
            // 单击即选，拖动才是自由框选。拾取失败（没给辅助功能权限、目标不支持 AX）
            // 由 PickService 退回整窗，再不行就当普通拖框，逐级降级不会挡路。
            //
            // 长截图例外：滚动会话要的是精确的滚动区域，悬停高亮只会干扰判读。
            var pickArea: PickProbe?
            if case .scroll = action {
                pickArea = nil
            } else {
                picker.invalidate()
                // 粒度由覆盖层决定：⇥ 可以在「元素/窗口区域」和「整窗」之间切
                pickArea = { [picker] point, display, kind in
                    picker.probe(kind: kind, at: point, in: display)
                }
            }
            // 标注不关覆盖层：框完直接原地变成编辑器，和 Longshot 一致
            selection = await overlay.select(from: frames,
                                             probe: pickArea,
                                             keepsSelection: action == .edit)
        case .window:
            picker.invalidate()
            selection = await overlay.select(from: frames, mode: .pick) { [picker] point, display, _ in
                picker.probe(kind: .window, at: point, in: display)
            }
        case .element:
            picker.invalidate()
            selection = await overlay.select(from: frames, mode: .pick) { [picker] point, display, _ in
                picker.probe(kind: .element, at: point, in: display)
            }
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
