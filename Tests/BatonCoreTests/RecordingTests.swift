import AVFoundation
import XCTest
@testable import BatonCore

/// 录制参数里唯一有真实规则的几处：帧率夹取、时长/尺寸下限。
/// 过滤器构造依赖 SCShareableContent（要真屏幕），留给 `--record` 探针验。
final class RecordingConfigTests: XCTestCase {
    private let url = URL(fileURLWithPath: "/tmp/baton-test.mp4")

    func testFrameRateIsClamped() {
        XCTAssertEqual(RecordingConfig(target: .fullScreen, url: url, frameRate: 5).frameRate, 10)
        XCTAssertEqual(RecordingConfig(target: .fullScreen, url: url, frameRate: 120).frameRate, 60)
        XCTAssertEqual(RecordingConfig(target: .fullScreen, url: url, frameRate: 30).frameRate, 30)
    }

    func testTargetTitles() {
        XCTAssertEqual(RecordingTarget.area.title, "区域录制")
        XCTAssertEqual(RecordingTarget.fullScreen.title, "全屏录制")
        XCTAssertEqual(RecordingTarget.window.title, "窗口录制")
        XCTAssertEqual(RecordingTarget.application.title, "应用录制")
    }

    func testAudioDefaultsOnAndCanBeDisabled() {
        XCTAssertTrue(RecordingConfig(target: .fullScreen, url: url).capturesAudio)
        XCTAssertFalse(RecordingConfig(target: .fullScreen, url: url, capturesAudio: false).capturesAudio)
    }

    func testErrorMessagesAreActionable() {
        // 报错文案会直接弹给用户，空字符串比错误码还糟
        for error in [RecordingError.screenRecordingDenied,
                      .microphoneDenied,
                      .targetNotFound,
                      .setupFailed("x"),
                      .writerFailed("y")] {
            XCTAssertFalse(error.message.isEmpty)
        }
    }
}

/// 录制偏好落在 recording.json：默认带声音，关掉后重启也得是关着的。
@MainActor
final class RecordingSettingsTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("baton-recording-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testDefaultsToAudioOn() {
        let store = RecordingSettingsStore(url: directory.appendingPathComponent("recording.json"))
        XCTAssertTrue(store.capturesAudio)
    }

    func testTogglePersistsToDisk() {
        let url = directory.appendingPathComponent("recording.json")
        let store = RecordingSettingsStore(url: url)
        store.setCapturesAudio(false)

        let reopened = RecordingSettingsStore(url: url)
        XCTAssertFalse(reopened.capturesAudio)
    }

    func testBrokenFileFallsBackToDefaults() throws {
        let url = directory.appendingPathComponent("recording.json")
        try Data("not json".utf8).write(to: url)
        XCTAssertTrue(RecordingSettingsStore(url: url).capturesAudio)
    }

    func testMicrophoneDefaultsOff() {
        let store = RecordingSettingsStore(url: directory.appendingPathComponent("recording.json"))
        XCTAssertFalse(store.capturesMicrophone, "麦克风一开就弹授权框，默认必须是关的")
    }

    func testMicrophoneTogglePersists() {
        let url = directory.appendingPathComponent("recording.json")
        RecordingSettingsStore(url: url).setCapturesMicrophone(true)
        XCTAssertTrue(RecordingSettingsStore(url: url).capturesMicrophone)
    }

    func testLegacyFileWithoutMicrophoneKeyKeepsAudioPreference() throws {
        // 老版本只写了 capturesAudio：加字段不能把用户「关掉声音」的选择重置掉
        let url = directory.appendingPathComponent("recording.json")
        try Data(#"{"capturesAudio": false}"#.utf8).write(to: url)
        let store = RecordingSettingsStore(url: url)
        XCTAssertFalse(store.capturesAudio)
        XCTAssertFalse(store.capturesMicrophone)
    }
}

/// 混音器把系统声音和麦克风按时间轴叠在一起：起点对齐、叠加削顶、前瞻出块、收尾 flush。
final class AudioMixerTests: XCTestCase {
    private let rate = CanonicalAudio.sampleRate

    private func segment(frames: Int, value: Float) -> CanonicalAudio.Segment {
        CanonicalAudio.Segment(frames: frames,
                               samples: [Float](repeating: value,
                                                count: frames * CanonicalAudio.channels))
    }

    private func pts(seconds: Double) -> CMTime {
        CMTime(value: CMTimeValue((seconds * rate).rounded()), timescale: CMTimeScale(rate))
    }

    func testSystemAndMicrophoneAreSummed() {
        let mixer = AudioMixer(lookaheadSeconds: 0)
        mixer.ingestMic(segment(frames: 480, value: 0.25), pts: pts(seconds: 0))
        let output = mixer.ingestSystem(segment(frames: 480, value: 0.5), pts: pts(seconds: 0))

        XCTAssertEqual(output.count, 1)
        XCTAssertEqual(output[0].samples.count, 480 * CanonicalAudio.channels)
        XCTAssertEqual(output[0].samples[0], 0.75, accuracy: 0.0001)
        XCTAssertEqual(output[0].pts, pts(seconds: 0))
    }

    func testSumIsClippedInsteadOfOverflowing() {
        let mixer = AudioMixer(lookaheadSeconds: 0)
        mixer.ingestMic(segment(frames: 480, value: 0.8), pts: pts(seconds: 0))
        let output = mixer.ingestSystem(segment(frames: 480, value: 0.8), pts: pts(seconds: 0))
        XCTAssertEqual(output[0].samples[0], 1.0, accuracy: 0.0001)
    }

    func testSystemWithoutMicrophonePassesThrough() {
        let mixer = AudioMixer(lookaheadSeconds: 0)
        let output = mixer.ingestSystem(segment(frames: 480, value: -0.4), pts: pts(seconds: 0))
        XCTAssertEqual(output[0].samples[0], -0.4, accuracy: 0.0001)
    }

    func testLookaheadHoldsBlocksUntilMicrophoneCanArrive() {
        let mixer = AudioMixer(lookaheadSeconds: 0.08)   // 3840 帧
        XCTAssertTrue(mixer.ingestSystem(segment(frames: 480, value: 0.5),
                                         pts: pts(seconds: 0)).isEmpty)
        // 又来了 8 个 480 帧的块，累计 4320 帧，超过前瞻窗口，第一块才放行
        var output: [(pts: CMTime, samples: [Float])] = []
        for index in 1...8 {
            output += mixer.ingestSystem(segment(frames: 480, value: 0.5),
                                         pts: pts(seconds: Double(index) * 0.01))
        }
        XCTAssertEqual(output.count, 1)
        XCTAssertEqual(output[0].pts, pts(seconds: 0))
    }

    func testFlushEmitsPendingBlocks() {
        let mixer = AudioMixer(lookaheadSeconds: 0.08)
        _ = mixer.ingestSystem(segment(frames: 480, value: 0.5), pts: pts(seconds: 0))
        XCTAssertEqual(mixer.pendingFrameCount, 1)
        XCTAssertEqual(mixer.flush().count, 1)
        XCTAssertEqual(mixer.pendingFrameCount, 0)
    }

    func testMicrophoneStartingLateStillMixesTheOverlap() {
        // 系统声音从 0 帧起、麦克风 240 帧才起：前半块只有系统声音，后半块要叠上
        let mixer = AudioMixer(lookaheadSeconds: 0.01)   // 480 帧
        _ = mixer.ingestSystem(segment(frames: 480, value: 0.5), pts: pts(seconds: 0))
        mixer.ingestMic(segment(frames: 240, value: 0.25), pts: pts(seconds: 0.005))
        let output = mixer.ingestSystem(segment(frames: 480, value: 0.5), pts: pts(seconds: 0.01))

        XCTAssertEqual(output.count, 1)
        let channels = CanonicalAudio.channels
        XCTAssertEqual(output[0].samples[0], 0.5, accuracy: 0.0001)               // 0 帧：还没麦克风
        XCTAssertEqual(output[0].samples[240 * channels], 0.75, accuracy: 0.0001) // 240 帧：叠上了
    }

    func testLongRecordingDoesNotGrowMicrophoneTimeline() {
        // 麦克风时间轴出块后要裁掉，否则 48k 立体声一分钟就几十 MB
        let mixer = AudioMixer(lookaheadSeconds: 0)
        mixer.ingestMic(segment(frames: 48_000, value: 0.1), pts: pts(seconds: 0))
        XCTAssertGreaterThan(mixer.micFrameCount, 40_000)
        for index in 0..<60 {
            _ = mixer.ingestSystem(segment(frames: 1200, value: 0.1),
                                   pts: pts(seconds: Double(index) * 0.025))
        }
        XCTAssertLessThan(mixer.micFrameCount, 48_000, "混过的麦克风数据必须被裁掉")
    }
}

/// 混音输出最终要交给 AVAssetWriter 编成 AAC：这里用 1 秒合成信号跑一遍真实写入，
/// 证明「自己造的 CMSampleBuffer」格式对、时长对、幅度没被搞坏。
final class CanonicalAudioTests: XCTestCase {
    func testMixedBuffersSurviveAACEncoding() async throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("baton-mix-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }

        let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128_000,
        ])
        input.expectsMediaDataInRealTime = false
        XCTAssertTrue(writer.canAdd(input))
        writer.add(input)
        XCTAssertTrue(writer.startWriting())
        writer.startSession(atSourceTime: .zero)

        let frames = 1024
        let blocks = 47   // 47 * 1024 ≈ 1.00 秒
        for index in 0..<blocks {
            while !input.isReadyForMoreMediaData {
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            let pts = CMTime(value: CMTimeValue(index * frames),
                             timescale: CMTimeScale(CanonicalAudio.sampleRate))
            let samples = [Float](repeating: 0.5, count: frames * CanonicalAudio.channels)
            let buffer = try XCTUnwrap(CanonicalAudio.makeBuffer(samples, frames: frames, pts: pts),
                                       "makeBuffer 造不出样本，混音根本写不进去")
            XCTAssertTrue(input.append(buffer))
        }
        input.markAsFinished()
        await writer.finishWriting()
        XCTAssertEqual(writer.status, .completed, writer.error?.localizedDescription ?? "")
        XCTAssertGreaterThan((try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0,
                             0)

        // 读回来核一遍：1 秒左右、峰值接近 0.5（AAC 有损，给宽一点的容差）
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(tracks.count, 1)
        let duration = try await asset.load(.duration)
        XCTAssertEqual(CMTimeGetSeconds(duration), 1.0, accuracy: 0.1)

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: try XCTUnwrap(tracks.first), outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
        ])
        reader.add(output)
        reader.startReading()
        var peak: Float = 0
        while let buffer = output.copyNextSampleBuffer() {
            guard let segment = CanonicalAudio.read(buffer) else { continue }
            for sample in segment.samples { peak = max(peak, abs(sample)) }
        }
        // 方波起停处 AAC 会过冲（0.5 读回来约 0.55），容差按这个给
        XCTAssertEqual(peak, 0.5, accuracy: 0.1, "编码回来幅度不对，说明写入的格式错了")
    }
}
