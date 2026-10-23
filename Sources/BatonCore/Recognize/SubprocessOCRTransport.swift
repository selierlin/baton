import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// OCR 子进程（`BatonOCR`）的父进程侧。
///
/// 为什么要拆进程：本机实测进程内跑一次 Vision 会让常驻内存 +30 MB 且 60 s 后只回落 0.1 MB；
/// 更要紧的是 Vision 一旦崩，主进程所有功能一起没。拆出去之后 OCR 的内存和崩溃都留在子进程，
/// 父进程只负责收发一行行 JSON。
///
/// 失败策略：子进程起不来或挂了 → 重启一次；再挂就永久退回进程内实现（功能不降级，只是回到旧路径），
/// 免得用户在没法排查的情况下连 OCR 都用不了。
public final class SubprocessOCRTransport: OCRTransport {
    public init() {}

    public var usesSubprocess: Bool { OCRWorker.shared.usesSubprocess }
    public var isDegraded: Bool { OCRWorker.shared.isDegraded }

    public func recognize(_ request: OCRRequest) async throws -> OCRResult {
        try await OCRWorker.shared.recognize(request)
    }

    /// 预热：抓帧的同时把子进程拉起来，省掉第一次识别的进程启动开销。
    public static func warmUp() {
        OCRWorker.shared.warmUp()
    }

    public static func shutdown() {
        OCRWorker.shared.shutdown()
    }
}

/// 单例：子进程只应存在一个。`OCRTransportFactory` 每次识别都会新建 transport，
/// 但真正持有 `Process` 的必须是这一份。
final class OCRWorker: @unchecked Sendable {
    static let shared = OCRWorker()

    private enum Limits {
        /// 单次识别上限。实测同尺寸 Vision 约 1.2 s、百度 1.3 s，60 s 只用来兜死锁。
        static let recognizeTimeout: TimeInterval = 60
        static let handshakeTimeout: TimeInterval = 10
        /// 连续失败到这个次数就永久退回进程内
        static let maxFailures = 2
    }

    private let queue = DispatchQueue(label: "com.selier.baton.ocr.worker")
    private let fallback = VisionOCRTransport()
    private let helperURL: URL?

    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var readBuffer = Data()

    private var failures = 0
    private var disabled = false

    var usesSubprocess: Bool {
        queue.sync { helperURL != nil && !disabled }
    }

    var isDegraded: Bool {
        queue.sync { disabled }
    }

    init(helperURL: URL? = OCRWorker.locateHelper()) {
        self.helperURL = helperURL
        // 子进程死掉后写管道会触发 SIGPIPE，默认动作是直接杀掉本进程
        _ = signal(SIGPIPE, SIG_IGN)
    }

    // MARK: - 对外

    func recognize(_ request: OCRRequest) async throws -> OCRResult {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try self.runLocked(request))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func warmUp() {
        guard helperURL != nil, !disabled else { return }
        // 只在本机 Vision 是当前 OCR 服务商时预热；百度那条用不上子进程
        if let settings = try? OCRSettingsStore().load(),
           settings.active?.kind != .vision {
            return
        }
        queue.async {
            guard !self.disabled else { return }
            try? self.ensureProcessLocked()
        }
    }

    func shutdown() {
        queue.sync { teardownLocked() }
    }

    // MARK: - 识别

    private func runLocked(_ request: OCRRequest) throws -> OCRResult {
        guard helperURL != nil, !disabled else {
            return try fallbackLocked(request)
        }
        guard let png = Self.pngBase64(request.image) else {
            throw OCRError.requestFailed("图片编码失败")
        }

        var lastError: Error?
        // 至多两次：第一次失败重启子进程再试，第二次失败就退回进程内
        for attempt in 0..<2 {
            do {
                try ensureProcessLocked()
                let id = UUID().uuidString
                let languages = request.languages.isEmpty
                    ? VisionOCRTransport.defaultLanguages
                    : request.languages
                let payload = try OCRWire.encode(
                    OCRWireRequest.ocr(id: id, pngBase64: png, languages: languages)
                )
                try writeLocked(payload)
                let response = try readResponseLocked(id: id, timeout: Limits.recognizeTimeout)
                if let error = response.error {
                    throw OCRError.requestFailed(error)
                }
                return OCRResult(lines: response.ocrLines, milliseconds: response.ms ?? 0)
            } catch {
                lastError = error
                teardownLocked()
                failures += 1
                if attempt == 1 || failures >= Limits.maxFailures {
                    disabled = true
                    break
                }
            }
        }

        // 子进程这条路彻底不行了：退回进程内，把原因留在日志里
        NSLog("[Baton] OCR 子进程不可用（%@），改用进程内 Vision", String(describing: lastError))
        return try fallbackLocked(request)
    }

    private func fallbackLocked(_ request: OCRRequest) throws -> OCRResult {
        let semaphore = DispatchSemaphore(value: 0)
        // 用 Result 包一层：Swift 6 下跨并发域传可变捕获会报错
        final class Box: @unchecked Sendable { var value: Result<OCRResult, Error>? }
        let box = Box()
        Task {
            do {
                box.value = .success(try await self.fallback.recognize(request))
            } catch {
                box.value = .failure(error)
            }
            semaphore.signal()
        }
        semaphore.wait()
        guard let value = box.value else { throw OCRError.requestFailed("OCR 未返回结果") }
        return try value.get()
    }

    // MARK: - 子进程生命周期

    private func ensureProcessLocked() throws {
        if let process, process.isRunning { return }
        guard let helperURL else { throw OCRError.requestFailed("找不到 OCR 子进程") }

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let child = Process()
        child.executableURL = helperURL
        child.arguments = []
        child.standardInput = stdinPipe
        child.standardOutput = stdoutPipe
        child.standardError = FileHandle.nullDevice

        try child.run()

        process = child
        input = stdinPipe.fileHandleForWriting
        output = stdoutPipe.fileHandleForReading
        readBuffer.removeAll(keepingCapacity: true)

        // 握手：确认子进程真的在应答，而不是「进程起来了但主循环没跑」
        let id = UUID().uuidString
        try writeLocked(try OCRWire.encode(OCRWireRequest.hello(id: id)))
        let response = try readResponseLocked(id: id, timeout: Limits.handshakeTimeout)
        if let error = response.error {
            teardownLocked()
            throw OCRError.requestFailed("OCR 子进程握手失败：\(error)")
        }
    }

    private func teardownLocked() {
        input?.closeFile()
        output?.closeFile()
        if let process, process.isRunning {
            process.terminate()
        }
        process = nil
        input = nil
        output = nil
        readBuffer.removeAll(keepingCapacity: false)
    }

    private func writeLocked(_ data: Data) throws {
        guard let input else { throw OCRError.requestFailed("OCR 子进程未启动") }
        try input.write(contentsOf: data)
    }

    /// 读到一行（换行结尾）为止。用 `poll` 做超时，别在死掉的子进程上无限等。
    private func readResponseLocked(id: String, timeout: TimeInterval) throws -> OCRWireResponse {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let newline = readBuffer.firstIndex(of: 0x0A) {
                let line = readBuffer[readBuffer.startIndex..<newline]
                readBuffer.removeSubrange(readBuffer.startIndex...newline)
                guard !line.isEmpty else { continue }
                let response = try OCRWire.decode(OCRWireResponse.self, from: Data(line))
                // 只认自己那一条；握手/上一次超时的残包直接丢掉
                if response.id == id { return response }
                continue
            }

            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { throw OCRError.requestFailed("OCR 子进程超时") }
            guard let output else { throw OCRError.requestFailed("OCR 子进程未启动") }

            var descriptor = pollfd(fd: output.fileDescriptor,
                                    events: Int16(POLLIN),
                                    revents: 0)
            let ready = poll(&descriptor, 1, Int32(remaining * 1000))
            if ready == 0 { throw OCRError.requestFailed("OCR 子进程超时") }
            if ready < 0 {
                if errno == EINTR { continue }
                throw OCRError.requestFailed("等待 OCR 子进程失败（errno \(errno)）")
            }
            guard let chunk = try output.read(upToCount: 1 << 16), !chunk.isEmpty else {
                throw OCRError.requestFailed("OCR 子进程已退出")
            }
            readBuffer.append(chunk)
        }
    }

    // MARK: - 工具

    /// 子进程位置：`Baton.app/Contents/MacOS/BatonOCR`。
    /// `swift run` / 单测里没有这个文件，调用方自然落到进程内实现。
    static func locateHelper() -> URL? {
        if let override = ProcessInfo.processInfo.environment["BATON_OCR_HELPER"],
           FileManager.default.isExecutableFile(atPath: override) {
            return URL(fileURLWithPath: override)
        }
        let candidate = Bundle.main.bundleURL
            .appendingPathComponent("Contents")
            .appendingPathComponent("MacOS")
            .appendingPathComponent("BatonOCR")
        return FileManager.default.isExecutableFile(atPath: candidate.path) ? candidate : nil
    }

    /// PNG 的 base64。压缩过的图比裸位图小一个数量级，跨进程拷贝才不会抵消拆进程的收益。
    static func pngBase64(_ image: CGImage) -> String? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return (data as Data).base64EncodedString()
    }
}
