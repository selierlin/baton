import AppKit
import CoreGraphics
import ImageIO
import ScreenCaptureKit

/// 冻结帧。`CGImage` 由 IOSurface 支撑，**不计入进程 footprint**，
/// 内存成本必须按 `image.bytesPerRow * image.height` 估算。
public final class CapturedFrame: @unchecked Sendable {
    public let image: CGImage
    public let display: DisplayFrame

    public init(image: CGImage, display: DisplayFrame) {
        self.image = image
        self.display = display
    }

    public var byteSize: Int { image.bytesPerRow * image.height }
}

public enum CaptureFailure: Error, Sendable {
    case screenRecordingDenied
    case noDisplays
    case captureFailed(String)
}

/// 连续抓同一块区域。
///
/// 长截图每帧都调一次 `ScreenCapturer.capture` 的话，每帧都要重新枚举
/// `SCShareableContent` 并重建 filter，实测单帧多花 26ms（8 次平均 68ms → 42ms，
/// 最坏 149ms）。抓帧慢一拍，手一快两帧就没重叠了，中间那段谁也补不回来。
/// 这里把 filter / config 建一次，循环里只发截图请求。
/// `@unchecked Sendable`：filter / config 在 init 里建好之后只读，同一时刻只有一个调用方
/// 持有它（长截图循环里逐帧 await），没有并发访问。不标的话新版 toolchain 不允许
/// 把这个类型的实例从非隔离的 async init 送回调用方。
public final class RegionCaptureSession: @unchecked Sendable {
    private let filter: SCContentFilter
    private let config: SCStreamConfiguration

    public init(rect: CGRect, display: DisplayFrame) async throws {
        guard CGPreflightScreenCaptureAccess() else {
            throw CaptureFailure.screenRecordingDenied
        }
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        } catch {
            throw CaptureFailure.captureFailed(error.localizedDescription)
        }
        guard let target = content.displays.first(where: { $0.displayID == display.displayID }) else {
            throw CaptureFailure.noDisplays
        }
        let selfApp = content.applications.first {
            $0.processID == ProcessInfo.processInfo.processIdentifier
        }
        // SCK 的 sourceRect 是「相对该屏左上角的点」，全局坐标直接减屏幕原点
        let local = CGRect(x: rect.minX - target.frame.minX,
                           y: rect.minY - target.frame.minY,
                           width: rect.width,
                           height: rect.height)
        filter = SCContentFilter(display: target,
                                 excludingApplications: selfApp.map { [$0] } ?? [],
                                 exceptingWindows: [])
        let scale = CGFloat(filter.pointPixelScale)

        config = SCStreamConfiguration()
        config.sourceRect = local
        config.width = max(1, Int(local.width * scale))
        config.height = max(1, Int(local.height * scale))
        config.showsCursor = false
        config.scalesToFit = false
        config.captureResolution = .best
    }

    public func capture() async throws -> CGImage {
        do {
            return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            throw CaptureFailure.captureFailed(error.localizedDescription)
        }
    }
}

/// 按窗口抓到的结果：位图 + 该窗口在全局显示坐标里的矩形（点）。
public struct WindowCapture: @unchecked Sendable {
    public let image: CGImage
    public let frame: CGRect

    public init(image: CGImage, frame: CGRect) {
        self.image = image
        self.frame = frame
    }
}

public enum ScreenCapturer {
    /// 按 windowID 抓单个窗口。
    ///
    /// 之前「窗口截图」是从冻结帧里裁一块矩形，窗口被别的 App 压着时截到的就是遮挡物。
    /// 这里换成真的按窗口抓，位图尺寸与窗口点尺寸严格对应，倍率换算不会歪。
    ///
    /// 走 `screencapture` 子进程而不是 SCK，是因为实测两条直连路径都不能用：
    /// - `SCScreenshotManager.captureImage` + `SCContentFilter(desktopIndependentWindow:)`
    ///   在本机（macOS 15.7.7 / M1）**永不返回**，48 秒都没回调；
    /// - 运行时取 `CGWindowListCreateImage` 虽然 40ms 出图，但对被完全遮挡的窗口
    ///   返回纯白——恰好是窗口截图最该解决的场景。
    /// `screencapture -l`（`-o` 去阴影）两条都正常，整体 90ms 左右，一次性操作可接受。
    public static func captureWindow(windowID: Int) async throws -> WindowCapture {
        guard CGPreflightScreenCaptureAccess() else {
            throw CaptureFailure.screenRecordingDenied
        }
        // 几何信息以 CGWindowList 为准：screencapture 只给位图，不给窗口矩形
        guard let info = WindowPicker.enumerate().first(where: { $0.windowID == windowID }) else {
            throw CaptureFailure.captureFailed("窗口已关闭或不在屏幕上")
        }
        guard info.bounds.width >= 1, info.bounds.height >= 1 else {
            throw CaptureFailure.captureFailed("窗口尺寸不可用")
        }
        let image = try await WindowShot.capture(windowID: windowID)
        return WindowCapture(image: image, frame: info.bounds)
    }

    /// 单次抓帧用这个即可；连续抓同一区域（长截图）请用 `RegionCaptureSession`，
    /// 它省掉每帧重新枚举 SCK 内容源的开销。
    public static func capture(rect: CGRect, display: DisplayFrame) async throws -> CGImage {
        let session = try await RegionCaptureSession(rect: rect, display: display)
        return try await session.capture()
    }

    /// 抓所有屏。非光标屏按 `nonCursorDownsample` 降采样（面积按平方缩小）。
    ///
    /// 为什么全部抓：覆盖窗建在所有屏并集上，缺一块屏就会在那一屏画出黑底。
    public static func captureAll(nonCursorDownsample: CGFloat = 0.5) async throws -> [CapturedFrame] {
        guard CGPreflightScreenCaptureAccess() else {
            throw CaptureFailure.screenRecordingDenied
        }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        } catch {
            throw CaptureFailure.captureFailed(error.localizedDescription)
        }
        guard !content.displays.isEmpty else { throw CaptureFailure.noDisplays }

        let selfApp = content.applications.first {
            $0.processID == ProcessInfo.processInfo.processIdentifier
        }
        var frames: [CapturedFrame] = []
        for display in content.displays {
            // 必须按单块 display 构造 filter，SCK 不支持多屏并集
            let filter = SCContentFilter(display: display,
                                         excludingApplications: selfApp.map { [$0] } ?? [],
                                         exceptingWindows: [])

            // SCDisplay.width/height 的单位是「点」，不是像素
            let scale = CGFloat(filter.pointPixelScale)

            let config = SCStreamConfiguration()
            config.width = max(1, Int(CGFloat(display.width) * scale))
            config.height = max(1, Int(CGFloat(display.height) * scale))
            config.showsCursor = false
            config.scalesToFit = false
            config.captureResolution = .best

            do {
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter,
                                                                      configuration: config)
                let frame = DisplayFrame(displayID: display.displayID,
                                         screenFrame: display.frame,
                                         pixelSize: CGSize(width: image.width, height: image.height),
                                         nativeScale: scale)
                frames.append(CapturedFrame(image: image, display: frame))
            } catch {
                throw CaptureFailure.captureFailed(error.localizedDescription)
            }
        }
        return frames
    }
}

/// `screencapture -l` 的薄封装：写临时 PNG，读回位图后立刻删掉。
///
/// 抽成独立类型是为了让 `ScreenCapturer.captureWindow` 的注释只讲「为什么不用 SCK」，
/// 这里只负责「怎么调」。
///
/// `waitUntilExit` 是阻塞调用：整段丢进 detached task，别占住主 actor——
/// 主线程一卡，覆盖层/HUD 的动画就直接丢帧。
enum WindowShot {
    /// `CGImage` 不是 `Sendable`，跨 task 传回时用这个盒子兜一层。
    private struct Box: @unchecked Sendable {
        let image: CGImage
    }

    static func capture(windowID: Int) async throws -> CGImage {
        try await Task.detached(priority: .userInitiated) {
            try Box(image: run(windowID: windowID)).image
        }.value
    }

    private static func run(windowID: Int) throws -> CGImage {
        let path = NSTemporaryDirectory() + "baton-window-\(UUID().uuidString).png"
        defer { try? FileManager.default.removeItem(atPath: path) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        // -x 不播声音，-o 去掉窗口阴影：带阴影时位图比窗口大一圈且四周留白不等宽，
        // 后面按「像素 ÷ 点」换算倍率就歪了。
        process.arguments = ["-x", "-o", "-l", String(windowID), path]
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            throw CaptureFailure.captureFailed("无法启动 screencapture：\(error.localizedDescription)")
        }
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw CaptureFailure.captureFailed("窗口抓取失败（退出码 \(process.terminationStatus)）")
        }
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else {
            throw CaptureFailure.captureFailed("窗口位图读取失败")
        }
        // 必须立刻解码：`CGImageSourceCreateImageAtIndex` 默认延迟解码，位图通过文件
        // 映射懒加载，函数返回后 `defer` 删掉临时文件，这张 CGImage 就成了空壳——
        // 实测表现是写 PNG 时 `finalize=false`、标注里一片空白。
        guard let image = CGImageSourceCreateImageAtIndex(
            source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary
        ) else {
            throw CaptureFailure.captureFailed("窗口位图解码失败")
        }
        return image
    }
}
