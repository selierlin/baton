import XCTest
@testable import BatonCore

@MainActor
final class DiagnosticBundleTests: XCTestCase {
    /// XCTestCase 的 setUp / tearDown 是非隔离的，Swift 6.1 会把这里的覆写
    /// 也当成 nonisolated（6.2 才改推断）。测试串行执行，加 nonisolated(unsafe) 直说。
    nonisolated(unsafe) private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("baton-diag-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    private func logLine(_ index: Int) -> String {
        String(format: "%02d:%02d:%02d.%03d [state ] input.switch  ABC -> doubao ok=true",
               index / 3600 % 24, index / 60 % 60, index % 60, index % 1000)
    }

    private func writeLog(_ lines: Int, into directory: URL, name: String = "baton.log") throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let text = (0..<lines).map(logLine).joined(separator: "\n") + "\n"
        try text.write(to: directory.appendingPathComponent(name),
                       atomically: true, encoding: .utf8)
    }

    private func snapshot() -> DiagnosticBundle.Snapshot {
        DiagnosticBundle.Snapshot(
            appVersion: "0.1.1 (77)",
            osVersion: "Version 15.7.3",
            architecture: "arm64",
            frontApp: "Google Chrome (com.google.Chrome)",
            input: .init(enabled: true,
                         switchDelayMs: 200,
                         currentSource: "com.bytedance.inputmethod.doubaoime.pinyin",
                         ruleCount: 3,
                         memoryCount: 12,
                         installed: ["com.apple.keylayout.ABC",
                                     "com.bytedance.inputmethod.doubaoime.pinyin"],
                         missingSources: ["搜狗拼音"])
        )
    }

    private func unzip(_ archive: URL, into directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, directory.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "解包失败")
    }

    func testExportContainsLogAndSummary() throws {
        let logs = root.appendingPathComponent("logs", isDirectory: true)
        try writeLog(20, into: logs)
        let output = root.appendingPathComponent("out", isDirectory: true)

        let archive = try DiagnosticBundle.export(snapshot(),
                                                  logDirectory: logs,
                                                  destinationDirectory: output)
        XCTAssertTrue(FileManager.default.fileExists(atPath: archive.path))
        XCTAssertTrue(archive.lastPathComponent.hasSuffix(".zip"))

        let unpacked = root.appendingPathComponent("unpacked", isDirectory: true)
        try unzip(archive, into: unpacked)

        let log = try String(contentsOf: unpacked.appendingPathComponent("baton.log"),
                             encoding: .utf8)
        XCTAssertEqual(log.split(separator: "\n").count, 20)

        let summary = try String(contentsOf: unpacked.appendingPathComponent("环境与输入法.txt"),
                                 encoding: .utf8)
        XCTAssertTrue(summary.contains("0.1.1 (77)"))
        XCTAssertTrue(summary.contains("切换延迟：200ms"))
        XCTAssertTrue(summary.contains("doubaoime.pinyin"))
        XCTAssertTrue(summary.contains("覆盖区间：00:00:00.000 ~ 00:00:19.019"))
        XCTAssertTrue(summary.contains("搜狗拼音"))
    }

    /// 日志只有时分秒、没有日期，只能按行数截尾；截断后首尾时间戳要跟着变。
    func testLogIsTrimmedToLastLines() throws {
        let logs = root.appendingPathComponent("logs", isDirectory: true)
        let total = DiagnosticBundle.logLineLimit + 25
        try writeLog(total, into: logs)

        let archive = try DiagnosticBundle.export(snapshot(),
                                                  logDirectory: logs,
                                                  destinationDirectory: root.appendingPathComponent("out"))
        let unpacked = root.appendingPathComponent("unpacked", isDirectory: true)
        try unzip(archive, into: unpacked)

        let log = try String(contentsOf: unpacked.appendingPathComponent("baton.log"),
                             encoding: .utf8)
        let lines = log.split(separator: "\n")
        XCTAssertEqual(lines.count, DiagnosticBundle.logLineLimit)
        XCTAssertEqual(String(lines.first ?? ""), logLine(25))
        XCTAssertEqual(String(lines.last ?? ""), logLine(total - 1))

        let summary = try String(contentsOf: unpacked.appendingPathComponent("环境与输入法.txt"),
                                 encoding: .utf8)
        XCTAssertTrue(summary.contains("只保留最后 \(DiagnosticBundle.logLineLimit) 行"))
    }

    /// 轮转后旧文件在前、新文件在后，拼起来才是完整时间线。
    func testRotatedLogIsReadFirst() throws {
        let logs = root.appendingPathComponent("logs", isDirectory: true)
        try writeLog(10, into: logs, name: "baton.log.1")
        try writeLog(10, into: logs, name: "baton.log")

        let archive = try DiagnosticBundle.export(snapshot(),
                                                  logDirectory: logs,
                                                  destinationDirectory: root.appendingPathComponent("out"))
        let unpacked = root.appendingPathComponent("unpacked", isDirectory: true)
        try unzip(archive, into: unpacked)

        let log = try String(contentsOf: unpacked.appendingPathComponent("baton.log"),
                             encoding: .utf8)
        let summary = try String(contentsOf: unpacked.appendingPathComponent("环境与输入法.txt"),
                                 encoding: .utf8)
        XCTAssertEqual(log.split(separator: "\n").count, 20)
        XCTAssertTrue(summary.contains("行数：20"))
    }

    /// 日志行不带日期，跨天时区间会看起来倒退；摘要得点明，别让人把时间线读反。
    func testSummaryMarksCrossDayCoverage() throws {
        let logs = root.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let text = "23:59:59.000 [app   ] launch\n00:00:01.000 [app   ] launch\n"
        try text.write(to: logs.appendingPathComponent("baton.log"), atomically: true, encoding: .utf8)

        let archive = try DiagnosticBundle.export(snapshot(),
                                                  logDirectory: logs,
                                                  destinationDirectory: root.appendingPathComponent("out"))
        let unpacked = root.appendingPathComponent("unpacked", isDirectory: true)
        try unzip(archive, into: unpacked)

        let summary = try String(contentsOf: unpacked.appendingPathComponent("环境与输入法.txt"),
                                 encoding: .utf8)
        XCTAssertTrue(summary.contains("跨天"))
    }

    func testMissingLogThrows() {
        XCTAssertThrowsError(try DiagnosticBundle.export(snapshot(),
                                                         logDirectory: root.appendingPathComponent("nope"),
                                                         destinationDirectory: root.appendingPathComponent("out")))
    }

    func testStampParsing() {
        XCTAssertEqual(DiagnosticBundle.stamp("12:34:56.789 [state] x"), "12:34:56.789")
        XCTAssertNil(DiagnosticBundle.stamp("==== Baton 0.1.1 ===="))
    }
}
