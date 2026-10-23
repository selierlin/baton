import AVFoundation
import AppKit
import CoreGraphics
import CoreMedia
import ScreenCaptureKit

/// 录什么。
public enum RecordingTarget: String, Sendable, Equatable {
    case area
    case fullScreen
    case window
    case application

    public var title: String {
        switch self {
        case .area: return "区域录制"
        case .fullScreen: return "全屏录制"
        case .window: return "窗口录制"
        case .application: return "应用录制"
        }
    }
}

public enum RecordingError: Error, Sendable {
    case screenRecordingDenied
    case microphoneDenied
    case targetNotFound
    case setupFailed(String)
    case writerFailed(String)

    public var message: String {
        switch self {
        case .screenRecordingDenied: return "缺少屏幕录制权限"
        case .microphoneDenied:
            return "缺少麦克风权限。到 系统设置 → 隐私与安全性 → 麦克风 里打开 Baton，"
                + "或在设置里关掉「录制麦克风旁白」。"
        case .targetNotFound: return "找不到要录的窗口或应用"
        case .setupFailed(let text): return "录制初始化失败：\(text)"
        case .writerFailed(let text): return "录制写入失败：\(text)"
        }
    }
}

/// 一次录制的参数。构造完就能直接喂给 `ScreenRecorder.start`。
public struct RecordingConfig: Sendable {
    public let target: RecordingTarget
    /// 仅区域/全屏用：全局显示坐标（点）
    public let rect: CGRect?
    public let displayID: CGDirectDisplayID?
    public let windowID: Int?
    public let ownerPID: pid_t?
    public let url: URL
    public let frameRate: Int
    /// 录系统声音（不含麦克风）。关掉就是纯画面
    public let capturesAudio: Bool
    /// 录麦克风旁白。开启后和系统声音混成一轨；单独开也行（纯旁白）
    public let capturesMicrophone: Bool

    public init(target: RecordingTarget,
                rect: CGRect? = nil,
                displayID: CGDirectDisplayID? = nil,
                windowID: Int? = nil,
                ownerPID: pid_t? = nil,
                url: URL,
                frameRate: Int = 30,
                capturesAudio: Bool = true,
                capturesMicrophone: Bool = false) {
        self.target = target
        self.rect = rect
        self.displayID = displayID
        self.windowID = windowID
        self.ownerPID = ownerPID
        self.url = url
        self.frameRate = max(10, min(frameRate, 60))
        self.capturesAudio = capturesAudio
        self.capturesMicrophone = capturesMicrophone
    }
}

/// SCStream → AVAssetWriter(H.264/MP4)。
///
/// 一条视频轨 + 一条音频轨（AAC）。音频来源可以是系统声音（SCK 的 `capturesAudio`）、
/// 麦克风旁白（`AVCaptureSession`），或两者混音——混音在 `AudioMixer` 里按时间轴叠加，
/// 成片始终只有一条音轨，不需要播放器/剪辑软件去处理多轨。
///
/// 四种模式共用一条管线，差别只在 `SCContentFilter`：
/// - 区域：display + `sourceRect`
/// - 全屏：display
/// - 窗口：`desktopIndependentWindow`
/// - 应用：display + `including: [app]`
///
/// 写入用 `expectsMediaDataInRealTime = true`：录制是实时流，
/// 让 writer 自己缓冲，别在采集回调里等磁盘。
public final class ScreenRecorder: NSObject, @unchecked Sendable {
    private let config: RecordingConfig
    /// writer 的尺寸设置是只读的、且必须在 `add` 之前定下来，
    /// 但真实像素尺寸得等拿到 `SCContentFilter` 才知道 —— 所以延迟到 `start()` 里构造。
    private var writer: AVAssetWriter!
    private var input: AVAssetWriterInput!
    private var audioInput: AVAssetWriterInput?
    private var stream: SCStream?
    private var mic: MicrophoneCapture?
    /// 只在系统声 + 麦克风同时开时才有：单路音频没必要混
    private var mixer: AudioMixer?
    private let queue = DispatchQueue(label: "com.selier.baton.record", qos: .userInitiated)
    /// 音频和视频分开排队：一条队列会被 30fps 的画面卡住，声音就一顿一顿的
    private let audioQueue = DispatchQueue(label: "com.selier.baton.record.audio", qos: .userInitiated)
    private let state = StateBox()

    public private(set) var startedAt: Date?
    /// 流被系统掐断（切分辨率、权限被回收）时立刻通知上层，别等用户点停止才发现
    public var onFailure: (@Sendable (String) -> Void)?

    public init(config: RecordingConfig) {
        self.config = config
        super.init()
    }

    /// 起流。返回时已经在录了。
    public func start() async throws {
        guard CGPreflightScreenCaptureAccess() else {
            throw RecordingError.screenRecordingDenied
        }
        // 先问麦克风权限：没授权就别把录制开到一半才发现没有旁白
        if config.capturesMicrophone {
            guard await MicrophoneCapture.requestAccess() else {
                throw RecordingError.microphoneDenied
            }
        }

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw RecordingError.setupFailed(error.localizedDescription)
        }

        let filter = try makeFilter(from: content)
        let scale = CGFloat(filter.pointPixelScale)
        // 区域/应用不是整屏：算出要裁的那块（显示器左上原点，点）
        let crop = cropRect(for: filter, in: content)
        let pixelSize = try pixelSize(crop: crop, filter: filter, scale: scale)
        // 位图尺寸必须和 writer 的设置一致，否则 AVAssetWriter 直接拒收样本
        try makeWriter(width: pixelSize.width, height: pixelSize.height)

        let configuration = SCStreamConfiguration()
        configuration.width = pixelSize.width
        configuration.height = pixelSize.height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(config.frameRate))
        configuration.queueDepth = 6
        configuration.showsCursor = true
        configuration.capturesAudio = config.capturesAudio
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.scalesToFit = false
        configuration.sourceRect = crop ?? .zero

        guard writer.startWriting() else {
            throw RecordingError.writerFailed(writer.error?.localizedDescription ?? "startWriting 失败")
        }

        // 混音器必须在 setCapture 之前建好：SCK 的音频回调一起来就会读它，
        // 晚一步创建的话前几块会「直接写」，之后混音块再把时间戳往回跳，writer 直接拒收
        if config.capturesMicrophone, config.capturesAudio { mixer = AudioMixer() }

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            if config.capturesAudio, audioInput != nil {
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
            }
            try await stream.startCapture()
        } catch {
            writer.cancelWriting()
            throw RecordingError.setupFailed(error.localizedDescription)
        }
        self.stream = stream

        if config.capturesMicrophone {
            let capture = MicrophoneCapture(queue: audioQueue)
            do {
                try capture.start { [weak self] buffer in
                    self?.handleMicrophone(buffer)
                }
                mic = capture
            } catch {
                // 麦克风起不来不该毁掉整段录制：画面和系统声音照录
                NSLog("[Baton] 麦克风启动失败，本次不录旁白：\(error)")
            }
        }
        startedAt = Date()
    }

    private func makeWriter(width: Int, height: Int) throws {
        do {
            writer = try AVAssetWriter(outputURL: config.url, fileType: .mp4)
        } catch {
            throw RecordingError.setupFailed(error.localizedDescription)
        }
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: 12_000_000,
                AVVideoMaxKeyFrameIntervalKey: config.frameRate * 2,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ]
        input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else {
            throw RecordingError.setupFailed("无法添加视频轨")
        }
        writer.add(input)

        guard config.capturesAudio || config.capturesMicrophone else { return }
        // 48kHz/立体声/AAC：MP4 里最保险的一组参数，QuickTime 和剪辑软件都吃
        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128_000,
        ]
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        audio.expectsMediaDataInRealTime = true
        if writer.canAdd(audio) {
            writer.add(audio)
            audioInput = audio
        }
        // 加不进去就退化成无声录制，别让整段录制因为音轨失败而报废
    }


    /// 停止并收尾。`finishedURL` 只有在写成功时才有值。
    public func stop() async -> Result<URL, RecordingError> {
        guard state.beginStopping() else {
            return .failure(.writerFailed("已经在停止中"))
        }
        let failureText = state.current.failure

        if let stream {
            try? await stream.stopCapture()
            self.stream = nil
        }
        mic?.stop()
        // 混音器只在 audio queue 上被碰过，flush 也回那条队列做，
        // 否则和还在路上的麦克风回调撞一起就是数据竞争
        audioQueue.sync { [self] in flushMixer() }
        mic = nil

        guard let writer, let input else {
            try? FileManager.default.removeItem(at: config.url)
            return .failure(.writerFailed("尚未开始录制"))
        }

        // 没有一帧进来时 writer 还没进入 writing 状态，finishWriting 会直接失败
        let didStart = state.current.started
        let lastPTS = state.current.lastPTS

        if let failureText {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: config.url)
            return .failure(.writerFailed(failureText))
        }
        guard didStart else {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: config.url)
            return .failure(.writerFailed("没有录到任何画面"))
        }

        // 画面静止时 SCK 不再发帧，最后一帧的 PTS 可能停在开始后几百毫秒。
        // `endSession` 把最后一帧拉长到停止那一刻，否则「录了 10 秒」会变成 0.3 秒的片子。
        // 两个时间值都要减掉暂停时长，否则暂停多久成片就长多久。
        let hostNow = CMClockGetTime(CMClockGetHostTimeClock())
        let paused = state.pausedTotal(now: hostNow)
        if lastPTS.isValid {
            let tail = CMTimeAdd(CMTimeSubtract(lastPTS, paused),
                                 CMTime(value: 1, timescale: CMTimeScale(config.frameRate)))
            writer.endSession(atSourceTime: CMTimeMaximum(CMTimeSubtract(hostNow, paused), tail))
        }

        input.markAsFinished()
        audioInput?.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else {
            let text = writer.error?.localizedDescription ?? "完成状态 \(writer.status.rawValue)"
            try? FileManager.default.removeItem(at: config.url)
            return .failure(.writerFailed(text))
        }
        return .success(config.url)
    }

    /// 取消：扔掉临时文件，不保存。
    public func cancel() async {
        _ = await stop()
        try? FileManager.default.removeItem(at: config.url)
    }

    // MARK: - 过滤器

    private func makeFilter(from content: SCShareableContent) throws -> SCContentFilter {
        // 录制边框和工具条是 Baton 自己的窗口：用户要看得见，成片里不能有。
        // 整屏/区域/应用三种按显示器合成的模式都把它们排除掉。
        let ownApp = content.applications.first { $0.processID == getpid() }
        let excluding = ownApp.map { [$0] } ?? []

        switch config.target {
        case .window:
            guard let windowID = config.windowID,
                  let window = content.windows.first(where: { $0.windowID == windowID }) else {
                throw RecordingError.targetNotFound
            }
            return SCContentFilter(desktopIndependentWindow: window)

        case .application:
            guard let pid = config.ownerPID,
                  let app = content.applications.first(where: { $0.processID == pid }),
                  let display = content.displays.first(where: { $0.displayID == config.displayID })
                      ?? content.displays.first else {
                throw RecordingError.targetNotFound
            }
            return SCContentFilter(display: display, including: [app], exceptingWindows: [])

        case .area, .fullScreen:
            guard let display = content.displays.first(where: { $0.displayID == config.displayID })
                    ?? content.displays.first else {
                // 锁屏 / 未授权时 SCK 会给出空显示器列表，报错要说人话
                throw RecordingError.setupFailed("拿不到可录制的显示器（锁屏或权限问题）")
            }
            return SCContentFilter(display: display,
                                   excludingApplications: excluding,
                                   exceptingWindows: [])
        }
    }

    /// 要裁的画面区域（显示器左上原点，单位点）。nil = 整屏。
    ///
    /// 应用录制不能按整屏出片：`including: [app]` 只是把别的 App 从合成里去掉，
    /// 画面仍是整块显示器，小窗口会被缩在角落。这里取该 App 所有窗口的并集。
    private func cropRect(for filter: SCContentFilter, in content: SCShareableContent) -> CGRect? {
        switch config.target {
        case .area:
            guard let rect = config.rect,
                  let display = content.displays.first(where: { $0.displayID == config.displayID })
                      ?? content.displays.first else { return nil }
            return CGRect(x: rect.minX - display.frame.minX,
                          y: rect.minY - display.frame.minY,
                          width: rect.width,
                          height: rect.height)
        case .application:
            guard let pid = config.ownerPID else { return nil }
            // 只算普通窗口：面板/浮层/菜单栏那些 layer ≠ 0 的会把并集撑出黑边
            let windows = content.windows.filter {
                $0.owningApplication?.processID == pid && $0.windowLayer == 0 && $0.frame.width > 1
            }
            guard let first = windows.first else { return nil }
            var union = first.frame
            for window in windows.dropFirst() { union = union.union(window.frame) }
            guard union.width > 1, union.height > 1 else { return nil }
            // 跨屏时按它所在的显示器换算，别把绝对坐标当相对坐标
            let display = content.displays.first(where: { $0.displayID == config.displayID })
                ?? content.displays.first
            guard let display else { return nil }
            union = union.intersection(display.frame)
            guard !union.isNull, union.width > 1, union.height > 1 else { return nil }
            return CGRect(x: union.minX - display.frame.minX,
                          y: union.minY - display.frame.minY,
                          width: union.width,
                          height: union.height)
        case .fullScreen, .window:
            return nil
        }
    }

    private func pixelSize(crop: CGRect?, filter: SCContentFilter,
                           scale: CGFloat) throws -> (width: Int, height: Int) {
        let size = crop?.size ?? filter.contentRect.size
        // H.264 要求偶数宽高，奇数会被拒
        let width = max(2, Int(size.width * scale) / 2 * 2)
        let height = max(2, Int(size.height * scale) / 2 * 2)
        guard width >= 2, height >= 2 else { throw RecordingError.setupFailed("录制区域太小") }
        return (width, height)
    }

    // MARK: - 收样本

    fileprivate func append(_ sampleBuffer: CMSampleBuffer) {
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let decision = state.prepareFrame()
        guard !decision.skip else { return }

        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }

        // 暂停过就整体前移时间戳，否则成片里会凭空多出暂停的那段时间
        let buffer = decision.shift == .zero
            ? sampleBuffer
            : (Self.retimed(sampleBuffer, shift: decision.shift) ?? sampleBuffer)

        let snapshot = state.current
        if !snapshot.started {
            guard writer.status == .writing else { return }
            // SCK 的 PTS 是 mach host time（开机以来的纳秒），不是从 0 开始。
            // 会话起点必须钉在第一帧的 PTS 上，否则成片时长 = 开机时长（实测 84 万秒）。
            let origin = CMSampleBufferGetPresentationTimeStamp(buffer)
            writer.startSession(atSourceTime: origin)
            state.markStarted(at: origin)
        }
        guard input.isReadyForMoreMediaData else { return }
        if input.append(buffer) {
            state.setLastPTS(pts)
        } else {
            state.setFailure(writer.error?.localizedDescription ?? "append 失败")
        }
    }

    /// 音频样本：和视频共用同一套暂停/平移规则，只是不做帧率判断。
    ///
    /// 两路都在时先攒进混音器，由混音器决定什么时候出块；单路直接写。
    fileprivate func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        guard audioInput != nil else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let snapshot = state.current
        // 混音器要按会话起点排时间轴：起点没定、正在暂停/收尾时一律不喂
        guard snapshot.started, !snapshot.stopping, !snapshot.audioBroken,
              snapshot.failure == nil, !snapshot.paused,
              snapshot.sessionStart.isValid, pts >= snapshot.sessionStart else { return }

        guard let mixer else {
            writeAudio(sampleBuffer, pts: pts)
            return
        }
        guard let segment = CanonicalAudio.read(sampleBuffer) else {
            // 摊不平（非 32 位浮点）就没法混：丢掉这一段，别把时间轴搞乱。
            // 真走到这里说明系统给了意外的格式，画面照录，声音少一段。
            NSLog("[Baton] 系统声音格式不认识，跳过混音")
            return
        }
        for block in mixer.ingestSystem(segment, pts: pts) {
            emit(block)
        }
    }

    /// 麦克风样本：有混音器就只入时间轴，等系统声音来对齐；否则当普通音轨直接写。
    fileprivate func handleMicrophone(_ sampleBuffer: CMSampleBuffer) {
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let snapshot = state.current
        guard snapshot.started, !snapshot.stopping, !snapshot.audioBroken,
              snapshot.failure == nil, !snapshot.paused,
              snapshot.sessionStart.isValid, pts >= snapshot.sessionStart else { return }

        guard let mixer else {
            writeAudio(sampleBuffer, pts: pts)
            return
        }
        // 有混音器时麦克风只能走时间轴：直接写会和压在前瞻里的块抢时间戳
        guard let segment = CanonicalAudio.read(sampleBuffer) else { return }
        mixer.ingestMic(segment, pts: pts)
    }

    /// 停止时把混音器里压着的块全吐出来，否则最后 80ms 的声音会丢。
    private func flushMixer() {
        guard let mixer else { return }
        for block in mixer.flush() { emit(block, allowWhenStopping: true) }
        self.mixer = nil
    }

    private func emit(_ block: (pts: CMTime, samples: [Float]), allowWhenStopping: Bool = false) {
        let frames = block.samples.count / CanonicalAudio.channels
        guard let buffer = CanonicalAudio.makeBuffer(block.samples, frames: frames, pts: block.pts) else {
            return
        }
        writeAudio(buffer, pts: block.pts, allowWhenStopping: allowWhenStopping)
    }

    /// 真正把一段音频交给 writer。暂停时丢样本、暂停过整体前移时间戳。
    private func writeAudio(_ sampleBuffer: CMSampleBuffer, pts: CMTime,
                            allowWhenStopping: Bool = false) {
        guard let audioInput else { return }
        let snapshot = state.current
        guard snapshot.started, !snapshot.audioBroken, snapshot.failure == nil, !snapshot.paused,
              allowWhenStopping || !snapshot.stopping else { return }
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
        // 第一帧视频之前的声音没有会话起点，写进去会让 writer 报「时间早于 startSession」
        guard snapshot.sessionStart.isValid, pts >= snapshot.sessionStart else { return }

        let shift = snapshot.pausedTotal
        let buffer = shift == .zero
            ? sampleBuffer
            : (Self.retimed(sampleBuffer, shift: shift) ?? sampleBuffer)

        guard audioInput.isReadyForMoreMediaData else { return }
        if !audioInput.append(buffer) {
            // 音轨出问题不该毁掉整段画面：只关掉音频，视频继续录完
            state.markAudioBroken()
        }
    }

    /// 把样本的时间戳整体减去 `shift`。暂停/继续靠它把空洞补平。
    private static func retimed(_ buffer: CMSampleBuffer, shift: CMTime) -> CMSampleBuffer? {
        var timing = CMSampleTimingInfo()
        timing.duration = CMSampleBufferGetDuration(buffer)
        timing.presentationTimeStamp = CMTimeSubtract(CMSampleBufferGetPresentationTimeStamp(buffer), shift)
        timing.decodeTimeStamp = .invalid
        var out: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault,
                                                           sampleBuffer: buffer,
                                                           sampleTimingEntryCount: 1,
                                                           sampleTimingArray: &timing,
                                                           sampleBufferOut: &out)
        return status == noErr ? out : nil
    }

    // MARK: - 暂停 / 继续

    /// 暂停时丢弃所有样本：写进去就是一段静止画面，不如不写、改用时间戳平移。
    public func pause() {
        state.setPaused(true, now: CMClockGetTime(CMClockGetHostTimeClock()))
    }

    public func resume() {
        state.setPaused(false, now: CMClockGetTime(CMClockGetHostTimeClock()))
    }

    public var isPaused: Bool { state.current.paused }

    /// 累计暂停了多少秒（含正在暂停的这段），提示条按它算「录了多久」。
    public var pausedSeconds: Double {
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        return CMTimeGetSeconds(state.pausedTotal(now: now))
    }
}

extension ScreenRecorder: SCStreamOutput {
    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
                       of type: SCStreamOutputType) {
        if type == .audio {
            appendAudio(sampleBuffer)
            return
        }
        guard type == .screen else { return }
        // idle 帧（窗口没变化）带 .idle 标记，是 0 字节的空样本，直接灌给 writer 会报错
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer,
                                                                       createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let statusRaw = attachments.first?[.status] as? Int,
              statusRaw == SCFrameStatus.complete.rawValue else {
            return
        }
        append(sampleBuffer)
    }
}

extension ScreenRecorder: SCStreamDelegate {
    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        state.setFailure(error.localizedDescription)
        onFailure?(error.localizedDescription)
    }
}

/// 采集回调（串行 queue）和停止流程（async）都会碰这几个字段，
/// 用一把锁把「读全量快照」和「单字段写」包成同步方法——
/// Swift 6 不允许在 async 函数体里直接调 `NSLock.lock()`。
private final class StateBox: @unchecked Sendable {
    struct Snapshot {
        var started = false
        var stopping = false
        var failure: String?
        var paused = false
        /// 最后一帧的原始 PTS（mach host time）
        var lastPTS = CMTime.invalid
        /// 暂停累计丢掉的时间，所有时间戳都要减去它
        var pausedTotal = CMTime.zero
        /// 会话起点（第一帧的 PTS）；音频早于它的样本要丢掉，writer 不收负时间
        var sessionStart = CMTime.invalid
        /// 音轨写坏了就只停音频，画面照录
        var audioBroken = false
        var pauseStartedAt = CMTime.invalid
    }

    struct FrameDecision {
        var skip: Bool
        var shift: CMTime
    }

    private var storage = Snapshot()
    private let lock = NSLock()

    var current: Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    /// 只有第一个调用者拿到 true，其余都是重入
    func beginStopping() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if storage.stopping { return false }
        storage.stopping = true
        return true
    }

    func markStarted(at origin: CMTime) {
        lock.lock()
        defer { lock.unlock() }
        storage.started = true
        storage.sessionStart = origin
    }

    func setFailure(_ text: String) {
        lock.lock()
        defer { lock.unlock() }
        storage.failure = text
    }

    func markAudioBroken() {
        lock.lock()
        defer { lock.unlock() }
        storage.audioBroken = true
    }

    func setLastPTS(_ time: CMTime) {
        lock.lock()
        defer { lock.unlock() }
        storage.lastPTS = time
    }

    func setPaused(_ value: Bool, now: CMTime) {
        lock.lock()
        defer { lock.unlock() }
        guard storage.paused != value else { return }
        storage.paused = value
        if value {
            storage.pauseStartedAt = now
        } else if storage.pauseStartedAt.isValid {
            // 按挂钟记账：画面静止时 SCK 好几秒才发一帧，
            // 用「相邻帧 PTS 差」估算暂停时长会把 2 秒算成 3 秒
            let gap = CMTimeSubtract(now, storage.pauseStartedAt)
            if gap > .zero { storage.pausedTotal = CMTimeAdd(storage.pausedTotal, gap) }
            storage.pauseStartedAt = .invalid
        }
    }

    /// 每帧进来先问一句：要不要丢、时间戳要减多少。
    func prepareFrame() -> FrameDecision {
        lock.lock()
        defer { lock.unlock() }
        if storage.stopping || storage.failure != nil || storage.paused {
            return FrameDecision(skip: true, shift: .zero)
        }
        return FrameDecision(skip: false, shift: storage.pausedTotal)
    }

    /// 停止时用：还在暂停中，这段也要算进去。
    func pausedTotal(now: CMTime) -> CMTime {
        lock.lock()
        defer { lock.unlock() }
        if storage.paused, storage.pauseStartedAt.isValid {
            let running = CMTimeSubtract(now, storage.pauseStartedAt)
            if running > .zero { return CMTimeAdd(storage.pausedTotal, running) }
        }
        return storage.pausedTotal
    }
}
