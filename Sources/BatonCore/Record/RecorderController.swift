import AppKit
import os

/// 录制的门面：管生命周期、控制条、落盘位置。
///
/// `ScreenRecorder` 只管「把流写进文件」，这里负责人看得到的那一层——
/// 同一次只允许一条录制，界面上的入口都从这里过一遍，避免两个流抢同一个 writer。
@MainActor
public final class RecorderController {
    private let log = Logger(subsystem: "com.selier.baton", category: "record")
    private var recorder: ScreenRecorder?
    private var bar: RecordingBar?
    private var frame: RecordingFrame?
    /// 预览窗要落在刚才那块屏上，停止时 `config` 已经不在作用域里了
    private var activeScreen: NSScreen?

    public private(set) var isRecording = false
    /// 录制状态变化：菜单栏图标要跟着变红点
    public var onStateChange: ((Bool) -> Void)?
    /// 收尾成功后的回调
    public var onFinish: ((URL) -> Void)?
    public var onFailure: ((String) -> Void)?

    private var preview: RecordingPreviewWindow?

    public init() {}

    /// 开始录制。返回时已经在录了，控制条和选区边框也已经浮出来。
    ///
    /// `highlight` 是要录的区域（CG 全局坐标）：区域/窗口/应用给具体矩形，
    /// 整屏给 nil（整屏画边框没有意义）。边框和控制条都在 Baton 自己的窗口里，
    /// 由 `ScreenRecorder` 在滤镜里排除，用户看得见、成片里没有。
    public func start(target: RecordingTarget, config: RecordingConfig,
                      highlight: CGRect? = nil) async throws {
        guard !isRecording else { return }

        let recorder = ScreenRecorder(config: config)
        recorder.onFailure = { [weak self] text in
            Task { @MainActor in self?.bar?.showFailure(text) }
        }

        // 边框先于起流出现：SCK 初始化要几百毫秒，这段空档里屏幕上什么都没有，
        // 用户会以为「框完就没了」。先把框画上，起流失败再撤。
        if let highlight {
            let mainScreenHeight = NSScreen.screens.first?.frame.height ?? 0
            let frame = RecordingFrame(globalRect: highlight, mainScreenHeight: mainScreenHeight)
            frame.orderFrontRegardless()
            self.frame = frame
        }

        do {
            try await recorder.start()
        } catch {
            teardownChrome()
            throw error
        }
        self.recorder = recorder
        isRecording = true
        onStateChange?(true)

        // 控制条贴在选区外侧；整屏录制没有选区，退回屏幕顶部居中
        let screen = Self.screen(for: config, highlight: highlight)
        activeScreen = screen
        let bar = RecordingBar(title: target.title,
                               screen: screen,
                               globalRect: highlight)
        bar.onStop = { [weak self] in
            Task { await self?.stop() }
        }
        bar.onCancel = { [weak self] in
            Task { await self?.cancel() }
        }
        bar.onTogglePause = { [weak self] paused in
            guard let self else { return }
            if paused {
                self.recorder?.pause()
            } else {
                self.recorder?.resume()
            }
        }
        bar.start()
        self.bar = bar

        log.info("开始\(target.title, privacy: .public) → \(config.url.path, privacy: .public)")
        ActionLog.action("record.start", "target=\(target.rawValue) audio=\(config.capturesAudio) mic=\(config.capturesMicrophone) url=\(config.url.lastPathComponent)")
    }

    /// 停止并保存。失败会走 `onFailure`，不会静默丢文件。
    public func stop() async {
        guard let recorder, isRecording else { return }
        isRecording = false
        teardownChrome()
        let seconds = Int(Date().timeIntervalSince(recorder.startedAt ?? Date()) - recorder.pausedSeconds)

        switch await recorder.stop() {
        case .success(let url):
            log.info("录制完成：\(url.lastPathComponent, privacy: .public) \(seconds)s")
            ActionLog.result("record.done", "seconds=\(seconds) file=\(url.lastPathComponent)")
            onStateChange?(false)
            self.recorder = nil
            onFinish?(url)
            // 录完给个能直接看的预览：只有一条「已保存」提示，用户没法确认框没框错
            let preview = RecordingPreviewWindow(url: url,
                                                 duration: max(seconds, 1),
                                                 screen: activeScreen)
            preview.show()
            self.preview = preview
        case .failure(let error):
            log.error("录制失败：\(error.message, privacy: .public)")
            ActionLog.fail("record.failed", "reason=\(error.message)")
            onStateChange?(false)
            self.recorder = nil
            onFailure?(error.message)
        }
    }

    /// 取消：文件直接删掉。
    public func cancel() async {
        guard let recorder, isRecording else { return }
        isRecording = false
        teardownChrome()
        await recorder.cancel()
        self.recorder = nil
        log.debug("录制已取消")
        onStateChange?(false)
    }

    /// 边框和控制条一起收：两者必须同生同死，否则会留下一个孤零零的红框。
    private func teardownChrome() {
        bar?.dismiss()
        bar = nil
        frame?.orderOut(nil)
        frame = nil
    }

    // MARK: - 落盘

    /// `~/Movies/Baton/Baton-20261023-140533.mp4`。取不到 Movies 就退到临时目录，
    /// 宁可放到 /tmp 也别因为目录问题丢掉整段录制。
    public static func destinationURL() -> URL {
        let stamp = timestamp()
        let base = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let folder = base.appendingPathComponent("Baton", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("Baton-\(stamp).mp4")
        }
        return folder.appendingPathComponent("Baton-\(stamp).mp4")
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }

    /// 选区落在哪块屏；没有选区（整屏/窗口）时退回 `config.rect` 或鼠标所在屏。
    private static func screen(for config: RecordingConfig, highlight: CGRect?) -> NSScreen? {
        if let rect = highlight ?? config.rect,
           let screen = NSScreen.screens.first(where: { $0.frame.intersects(rect) }) {
            return screen
        }
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main
    }
}
