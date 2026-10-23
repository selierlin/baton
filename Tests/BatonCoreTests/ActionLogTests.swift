import XCTest
@testable import BatonCore

/// 日志是开发期唯一的「事后现场」，格式坏了就等于没有。
final class ActionLogTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("baton-log-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    func testWritesReadableLines() throws {
        let log = ActionLog(directory: directory)
        log.write(.action, "pin.created", "count=2")
        log.flush()

        let text = try String(contentsOf: log.fileURL, encoding: .utf8)
        XCTAssertTrue(text.contains("==== Baton"), "缺少会话头，不知道是哪次启动")
        XCTAssertTrue(text.contains("[action]"), "kind 没写进日志")
        XCTAssertTrue(text.contains("pin.created"), "动作名没写进日志")
        XCTAssertTrue(text.contains("count=2"), "参数没写进日志")
    }

    func testDetailIsOptionalAndLongNamesSurvive() throws {
        let log = ActionLog(directory: directory)
        log.write(.fail, "a.very.long.action.name.that.exceeds.the.column")
        log.flush()

        let text = try String(contentsOf: log.fileURL, encoding: .utf8)
        // 定宽只是为了对齐，超长名字不能被截断——截断会丢定位信息
        XCTAssertTrue(text.contains("a.very.long.action.name.that.exceeds.the.column"))
    }

    func testSecondSessionAppendsInsteadOfTruncating() throws {
        // 崩溃后重启，上一次的现场必须还在
        let first = ActionLog(directory: directory)
        first.write(.action, "before.crash")
        first.flush()

        let second = ActionLog(directory: directory)
        second.write(.action, "after.restart")
        second.flush()

        let text = try String(contentsOf: second.fileURL, encoding: .utf8)
        XCTAssertTrue(text.contains("before.crash"))
        XCTAssertTrue(text.contains("after.restart"))
    }
}
