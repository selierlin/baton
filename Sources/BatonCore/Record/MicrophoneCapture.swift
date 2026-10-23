import AVFoundation
import CoreMedia
import Foundation

/// 麦克风旁白采集。
///
/// 只负责「把麦克风变成一串统一格式的 CMSampleBuffer」，混音交给 `AudioMixer`：
/// 两件事分开，麦克风换设备/换格式都不影响混音逻辑。
///
/// 采样直接要求 48kHz / 立体声 / 32 位浮点交错 —— 和 `CanonicalAudio` 一致，
/// 混音时不用再做格式转换。
final class MicrophoneCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    enum Failure: Error {
        case noDevice
        case notAuthorized
        case cannotConfigure(String)
    }

    private let session = AVCaptureSession()
    private let output = AVCaptureAudioDataOutput()
    private let queue: DispatchQueue
    private var handler: ((CMSampleBuffer) -> Void)?
    private var running = false

    init(queue: DispatchQueue) {
        self.queue = queue
        super.init()
    }

    // MARK: - 权限

    static var isAuthorized: Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    /// 已授权直接返回 true；没问过就弹系统授权框（必须在主线程调用）。
    static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }

    // MARK: - 起停

    func start(handler: @escaping (CMSampleBuffer) -> Void) throws {
        guard Self.isAuthorized else { throw Failure.notAuthorized }
        guard let device = AVCaptureDevice.default(for: .audio) else { throw Failure.noDevice }

        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            throw Failure.cannotConfigure(error.localizedDescription)
        }

        session.beginConfiguration()
        defer { session.commitConfiguration() }

        guard session.canAddInput(input) else {
            throw Failure.cannotConfigure("无法添加麦克风输入")
        }
        session.addInput(input)

        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: CanonicalAudio.sampleRate,
            AVNumberOfChannelsKey: CanonicalAudio.channels,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        guard session.canAddOutput(output) else {
            throw Failure.cannotConfigure("无法添加麦克风输出")
        }
        session.addOutput(output)
        output.setSampleBufferDelegate(self, queue: queue)

        self.handler = handler
        running = true
        // startRunning 会阻塞几百毫秒（要等设备打开），别卡在主线程
        queue.async { [self] in session.startRunning() }
    }

    func stop() {
        guard running else { return }
        running = false
        handler = nil
        queue.async { [self] in
            session.stopRunning()
            output.setSampleBufferDelegate(nil, queue: nil)
        }
    }

    // MARK: - 回调

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        handler?(sampleBuffer)
    }
}
