import Foundation
import os

/// 日志行类型。前四种足够回答「用户做了什么 / 结果如何 / 为什么失败」，
/// `modal` 专门用来抓「弹了个框但看不见」这类卡死，`state` 记内部状态切换。
public enum LogKind: String, Sendable {
    case app
    case action
    case result
    case fail
    case modal
    case state
}

/// 落盘的运行日志（`~/Library/Logs/Baton/baton.log`）。
///
/// 为什么不用 `Logger` 就够：`log.debug` 默认不落盘，`log show` 还得限定时间窗，
/// 用户报「刚才卡住了」时往往已经错过。这里每条都写文件，出问题直接让对方把文件发过来。
///
/// 写入走独立串行队列，主线程只负责拼一行字符串；
/// 超过 4 MB 轮转成 `baton.log.1`，只留一份旧文件，避免长期跑把磁盘吃满。
public final class ActionLog: @unchecked Sendable {
    public static let shared = ActionLog()

    /// 日志目录，菜单里的「打开日志文件夹」用它。
    public let directory: URL
    public var fileURL: URL { directory.appendingPathComponent("baton.log") }

    private let queue = DispatchQueue(label: "com.selier.baton.actionlog", qos: .utility)
    private let logger = Logger(subsystem: "com.selier.baton", category: "log")
    private let clock: () -> Date
    private var handle: FileHandle?
    private var written: UInt64 = 0
    private var wroteHeader = false
    private let limit: UInt64 = 4 * 1024 * 1024

    /// 生产用：`~/Library/Logs/Baton`。测试可以传临时目录。
    init(directory: URL? = nil, clock: @escaping () -> Date = Date.init) {
        let base = directory ?? Self.defaultDirectory()
        self.directory = base
        self.clock = clock
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    /// 单测里走临时目录：测试会调真实的 PinController / CaptureSession，
    /// 如果都写进 `~/Library/Logs/Baton`，用户真正的现场会被测试噪音冲掉。
    private static func defaultDirectory() -> URL {
        if isRunningTests {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("BatonTests-log", isDirectory: true)
        }
        return FileManager.default
            .urls(for: .libraryDirectory, in: .userDomainMask).first
            .map { $0.appendingPathComponent("Logs/Baton", isDirectory: true) }
            ?? URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/Baton")
    }

    /// `swift test` 走 SwiftPM，不一定设 `XCTestConfigurationFilePath`；
    /// 链接了 XCTest 就一定能在运行时找到这个类。
    private static var isRunningTests: Bool {
        NSClassFromString("XCTestCase") != nil
            || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || Bundle.main.bundlePath.hasSuffix(".xctest")
    }

    // MARK: - 写入

    public func write(_ kind: LogKind, _ name: String, _ detail: String = "") {
        // 时间戳和格式化都放到串行队列里做：DateFormatter 不是线程安全的，
        // 而且主线程只该付出「传三个参数」的成本。
        let onMain = Thread.isMainThread
        queue.async { [self] in
            let stamp = Self.timeFormatter.string(from: clock())
            let line = "\(stamp) [\(kind.rawValue.padded(to: 6))] \(name.padded(to: 26))"
                + (detail.isEmpty ? "" : " \(detail)")
                + (onMain ? "" : " [bg]") + "\n"
            logger.notice("\(line, privacy: .public)")
            append(line)
        }
    }

    /// 等落盘完成。探针/测试用；正常代码别在主线程调。
    public func flush() {
        queue.sync {}
    }

    private func append(_ line: String) {
        if !wroteHeader {
            wroteHeader = true
            let day = Self.dateFormatter.string(from: clock())
            appendRaw("==== Baton \(Self.version) pid=\(getpid()) macOS \(Self.osVersion) \(day) ====\n")
        }
        appendRaw(line)
    }

    private func appendRaw(_ text: String) {
        guard let data = text.data(using: .utf8) else { return }
        if handle == nil { open() }
        if written + UInt64(data.count) > limit { rotate() }
        guard let handle else { return }
        do {
            try handle.write(contentsOf: data)
            written += UInt64(data.count)
        } catch {
            // 磁盘满 / 权限没了：关掉句柄下次重开，别在日志里递归写日志
            self.handle = nil
        }
    }

    private func open() {
        let manager = FileManager.default
        if !manager.fileExists(atPath: fileURL.path) {
            manager.createFile(atPath: fileURL.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: fileURL)
        _ = try? handle?.seekToEnd()
        written = (try? manager.attributesOfItem(atPath: fileURL.path)[.size] as? UInt64) ?? 0
    }

    private func rotate() {
        try? handle?.close()
        handle = nil
        let old = directory.appendingPathComponent("baton.log.1")
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.moveItem(at: fileURL, to: old)
        written = 0
        open()
    }

    // MARK: - 格式化

    /// 只在 `queue` 上访问（`write` 不直接用它），不会并发。
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
    private static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(short)(\(build))"
    }

    private static var osVersion: String {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }
}

// MARK: - 便捷入口

public extension ActionLog {
    /// 一条用户意图：点了哪个菜单 / 按了哪个热键 / 拖了一次框。
    static func action(_ name: String, _ detail: String = "") { shared.write(.action, name, detail) }
    /// 动作成功后的关键数据：区域、尺寸、耗时、条数。
    static func result(_ name: String, _ detail: String = "") { shared.write(.result, name, detail) }
    /// 失败或降级。写清原因，不要只写「失败」。
    static func fail(_ name: String, _ detail: String = "") { shared.write(.fail, name, detail) }
    /// 模态框进出。`open` 没有配对的 `close` 就是「看起来卡死」的那一类问题。
    static func modal(_ name: String, _ detail: String = "") { shared.write(.modal, name, detail) }
    static func state(_ name: String, _ detail: String = "") { shared.write(.state, name, detail) }
    static func app(_ name: String, _ detail: String = "") { shared.write(.app, name, detail) }
}

private extension String {
    /// 定宽对齐，方便直接 `grep` 和肉眼扫。超长不截断（截断会丢信息）。
    func padded(to width: Int) -> String {
        count >= width ? self : self + String(repeating: " ", count: width - count)
    }
}
