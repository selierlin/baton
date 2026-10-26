import AppKit
import CoreGraphics

/// 屏幕尺子：冻结当前画面，在整屏上量像素、量间距、吸颜色。
///
/// 与截图不同，尺子没有「框选→确认」这一步：一进来就能操作，
/// 退出前一直停在冻结帧上，所以屏幕内容是静止的，读数也不会被滚动打扰。
@MainActor
public final class RulerController {
    public enum Outcome: Sendable {
        case finished
        case cancelled
        case failed(String)
    }

    private let overlay = OverlayController()
    private var canvases: [RulerCanvasView] = []
    private var continuation: CheckedContinuation<Outcome, Never>?
    private let settings: RulerSettingsStore

    /// 在尺子里量完一块区域后直接按 ↩ 去标注：给出裁好的图和倍率。
    public var onCaptureArea: ((CGImage, CGSize) -> Void)?

    public init(settings: RulerSettingsStore = RulerSettingsStore()) {
        self.settings = settings
    }

    public var isActive: Bool { !canvases.isEmpty }

    public func run() async -> Outcome {
        guard !isActive else { return .cancelled }

        let frames: [CapturedFrame]
        do {
            frames = try await ScreenCapturer.captureAll()
        } catch CaptureFailure.screenRecordingDenied {
            PermissionCenter.request(.screenRecording)
            return .failed("缺少屏幕录制权限")
        } catch {
            return .failed(String(describing: error))
        }

        let hosts = overlay.stage(from: frames)
        guard hosts.count == frames.count, !hosts.isEmpty else {
            overlay.dismiss()
            return .failed("没有可用的屏幕")
        }

        return await withCheckedContinuation { continuation in
            self.continuation = continuation

            for (host, frame) in zip(hosts, frames) {
                let canvas = RulerCanvasView(image: frame.image, settings: settings.settings)
                canvas.frame = host.bounds
                canvas.autoresizingMask = [.width, .height]
                canvas.onFinish = { [weak self] finished in
                    self?.finish(finished ? .finished : .cancelled)
                }
                canvas.onCapture = { [weak self] image, scale in
                    self?.handOff(image, scale: scale)
                }
                host.addSubview(canvas)
                canvases.append(canvas)
            }

            // 尺子开着时在设置页改单位/线色，这边立刻跟着变
            settings.addObserver { [weak self] updated in
                guard let self else { return }
                for canvas in self.canvases { canvas.apply(updated) }
            }

            if let first = canvases.first {
                first.window?.makeFirstResponder(first)
            }
        }
    }

    /// 外部打断（新的截图开始了、App 退出）也走这里，避免 continuation 永久挂着。
    public func cancel() {
        finish(.cancelled)
    }

    /// 先收掉尺子的覆盖层，再把裁好的图交给标注——顺序反了会看到两层冻结帧叠着。
    private func handOff(_ image: CGImage, scale: CGSize) {
        let handler = onCaptureArea
        finish(.finished)
        handler?(image, scale)
    }

    private func finish(_ result: Outcome) {
        guard let continuation else { return }
        self.continuation = nil

        for canvas in canvases {
            canvas.removeFromSuperview()
        }
        canvases.removeAll()
        overlay.dismiss()
        continuation.resume(returning: result)
    }
}
