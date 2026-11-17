import Foundation

/// 导出「出问题时能离线看」的诊断包。
///
/// 只在本地生成一个 zip，不做任何网络请求——交给谁由用户自己决定。
/// 内容只有运行日志和环境状态，不采集截图、OCR 文字、剪贴板内容或按键。
@MainActor
public enum DiagnosticBundle {
    /// 日志最多带这么多行。日志行只有时分秒、没有日期，跨天没法按时间切，
    /// 只能按行数截尾；摘要里会写上首尾时间戳，拿到包能对上现场。
    public static let logLineLimit = 8000

    public struct Snapshot: Sendable {
        public struct InputState: Sendable {
            public var enabled: Bool
            public var switchDelayMs: Int
            public var currentSource: String
            public var ruleCount: Int
            public var memoryCount: Int
            public var installed: [String]
            public var missingSources: [String]

            public init(enabled: Bool,
                        switchDelayMs: Int,
                        currentSource: String,
                        ruleCount: Int,
                        memoryCount: Int,
                        installed: [String],
                        missingSources: [String]) {
                self.enabled = enabled
                self.switchDelayMs = switchDelayMs
                self.currentSource = currentSource
                self.ruleCount = ruleCount
                self.memoryCount = memoryCount
                self.installed = installed
                self.missingSources = missingSources
            }
        }

        public var appVersion: String
        public var osVersion: String
        public var architecture: String
        public var frontApp: String
        public var input: InputState

        public init(appVersion: String,
                    osVersion: String,
                    architecture: String,
                    frontApp: String,
                    input: InputState) {
            self.appVersion = appVersion
            self.osVersion = osVersion
            self.architecture = architecture
            self.frontApp = frontApp
            self.input = input
        }
    }

    public enum ExportError: LocalizedError {
        case noLog
        case zipFailed(Int32)

        public var errorDescription: String? {
            switch self {
            case .noLog:
                return "找不到 Baton 的运行日志"
            case .zipFailed(let code):
                return "打包失败（ditto 退出码 \(code)）"
            }
        }
    }

    /// 导出到 `~/Downloads/Baton-诊断-<时间>.zip`，返回 zip 的路径。
    @discardableResult
    public static func export(_ snapshot: Snapshot,
                              logDirectory: URL = ActionLog.shared.directory,
                              destinationDirectory: URL? = nil) throws -> URL {
        let log = try recentLog(in: logDirectory)

        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("Baton-Diag-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        try log.text.write(to: staging.appendingPathComponent("baton.log"),
                           atomically: true, encoding: .utf8)
        try summary(snapshot, log: log)
            .write(to: staging.appendingPathComponent("环境与输入法.txt"),
                   atomically: true, encoding: .utf8)

        let directory = destinationDirectory ?? downloadsDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(
            "Baton-诊断-\(Self.fileStamp.string(from: Date())).zip")
        try? FileManager.default.removeItem(at: destination)
        try zip(staging, to: destination)
        return destination
    }

    // MARK: - 日志切片

    struct LogSlice {
        let text: String
        let firstStamp: String?
        let lastStamp: String?
        let lineCount: Int
        let truncated: Bool
    }

    private static func recentLog(in directory: URL) throws -> LogSlice {
        // 旧文件在前、新文件在后；两份都读进来再截尾，才跨得过轮转边界
        let files = ["baton.log.1", "baton.log"]
            .map { directory.appendingPathComponent($0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !files.isEmpty else { throw ExportError.noLog }

        var lines: [String] = []
        for file in files {
            guard let data = try? Data(contentsOf: file),
                  let text = String(data: data, encoding: .utf8) else { continue }
            // 每行都带换行，末尾也会多出一个空串；空行不算数，否则行数多算一行
            lines.append(contentsOf: text.split(separator: "\n", omittingEmptySubsequences: true)
                .map(String.init))
        }
        guard !lines.isEmpty else { throw ExportError.noLog }

        let truncated = lines.count > logLineLimit
        let tail = truncated ? Array(lines.suffix(logLineLimit)) : lines
        let stamps = tail.compactMap(Self.stamp)
        return LogSlice(text: tail.joined(separator: "\n") + "\n",
                        firstStamp: stamps.first,
                        lastStamp: stamps.last,
                        lineCount: tail.count,
                        truncated: truncated)
    }

    /// 行首的 `HH:mm:ss.SSS`。日志格式是定宽的，够用且比正则便宜。
    static func stamp(_ line: String) -> String? {
        let chars = Array(line.prefix(12))
        guard chars.count == 12,
              chars[0].isNumber, chars[1].isNumber, chars[2] == ":",
              chars[3].isNumber, chars[4].isNumber, chars[5] == ":",
              chars[6].isNumber, chars[7].isNumber, chars[8] == ".",
              chars[9].isNumber, chars[10].isNumber, chars[11].isNumber else { return nil }
        return String(chars)
    }

    // MARK: - 摘要

    private static func summary(_ snapshot: Snapshot, log: LogSlice) -> String {
        let input = snapshot.input
        // 日志行只有时分秒：跨天时末尾会小于开头，标出来免得把区间读反
        let coverage: String
        if let first = log.firstStamp, let last = log.lastStamp {
            coverage = first <= last ? "\(first) ~ \(last)" : "\(first) ~ \(last)（跨天，行首不含日期）"
        } else {
            coverage = "（无法识别时间戳）"
        }

        var lines = [
            "导出时间：\(Self.readableStamp.string(from: Date()))",
            "Baton 版本：\(snapshot.appVersion)",
            "macOS：\(snapshot.osVersion)",
            "架构：\(snapshot.architecture)",
            "前台 App：\(snapshot.frontApp)",
            "",
            "输入法自动切换",
            "  开关：\(input.enabled ? "开" : "关")",
            "  切换延迟：\(input.switchDelayMs)ms",
            "  当前源：\(input.currentSource)",
            "  App 规则：\(input.ruleCount) 条",
            "  App 记忆：\(input.memoryCount) 条",
            "  可用源：",
        ]
        lines.append(contentsOf: input.installed.isEmpty
            ? ["    （读不到）"]
            : input.installed.map { "    \($0)" })
        lines.append("  失效源：\(input.missingSources.isEmpty ? "无" : input.missingSources.joined(separator: "、"))")
        lines.append("")
        lines.append("日志")
        lines.append("  文件：baton.log")
        lines.append("  行数：\(log.lineCount)\(log.truncated ? "（只保留最后 \(logLineLimit) 行）" : "")")
        lines.append("  覆盖区间：\(coverage)")
        lines.append("")
        lines.append("说明")
        lines.append("  · 本包不含截图、OCR 文字、剪贴板内容与按键记录")
        lines.append("  · 日志里可能包含前台 App 名称、网页域名、输入框提示文字")
        lines.append("  · 导出动作本身在日志里记作 diag.export")
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - 打包

    private static func zip(_ directory: URL, to destination: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        // 不带 --keepParent：解压后直接是 baton.log 和摘要，不套一层临时目录名
        process.arguments = ["-c", "-k", "--sequesterRsrc", directory.path, destination.path]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ExportError.zipFailed(process.terminationStatus)
        }
    }

    private static var downloadsDirectory: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Downloads", isDirectory: true)
    }

    private static let fileStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    private static let readableStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
}
