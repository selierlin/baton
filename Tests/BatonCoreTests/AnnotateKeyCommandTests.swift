import AppKit
import XCTest
@testable import BatonCore

/// 标注态的单键命令：键位与 Longshot 一致，靠 keyDown 分发。
///
/// 这些键都带副作用（打开外部 App、弹识别面板、写剪贴板），
/// 只能测「分发到了哪个命令」，不能在这里真的执行。
@MainActor
final class AnnotateKeyCommandTests: XCTestCase {
    private func makeCanvas() -> (AnnotateCanvasView, NSWindow) {
        let context = CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let canvas = AnnotateCanvasView(image: context.makeImage()!, style: AnnotateStyle())
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 100, height: 100),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = canvas
        return (canvas, window)
    }

    private func press(_ canvas: AnnotateCanvasView, _ window: NSWindow,
                       characters: String, code: UInt16,
                       flags: NSEvent.ModifierFlags = []) -> AnnotateCommand? {
        var captured: AnnotateCommand?
        canvas.onCommand = { captured = $0 }
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero,
                                           modifierFlags: flags,
                                           timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil,
                                           characters: characters,
                                           charactersIgnoringModifiers: characters,
                                           isARepeat: false, keyCode: code) else {
            XCTFail("构造按键失败")
            return nil
        }
        canvas.keyDown(with: event)
        return captured
    }

    func testPlainKeysMapToExportCommands() {
        let (canvas, window) = makeCanvas()
        XCTAssertEqual(press(canvas, window, characters: "o", code: 31), .open)
        XCTAssertEqual(press(canvas, window, characters: "a", code: 0), .airDrop)
        XCTAssertEqual(press(canvas, window, characters: "r", code: 15), .ocr(silent: false))
        XCTAssertEqual(press(canvas, window, characters: "p", code: 35), .pin)
    }

    func testCommandRRecognizesSilently() {
        let (canvas, window) = makeCanvas()
        let command = press(canvas, window, characters: "r", code: 15, flags: .command)
        XCTAssertEqual(command, .ocr(silent: true), "⌘R 识别后只进剪贴板，不弹面板")
    }

    func testOptionQDecodesQR() {
        let (canvas, window) = makeCanvas()
        // Option 会把字符改成 œ，所以这条只能靠 keyCode 认
        let command = press(canvas, window, characters: "œ", code: 12, flags: .option)
        XCTAssertEqual(command, .qr)
    }

    func testDigitKeysStillSwitchTools() {
        let (canvas, window) = makeCanvas()
        canvas.tool = .select
        _ = press(canvas, window, characters: "1", code: 18)
        XCTAssertEqual(canvas.tool, .rectangle)

        // 连按同一个键在组内轮换（Longshot 的「连续按切换」）
        _ = press(canvas, window, characters: "1", code: 18)
        XCTAssertEqual(canvas.tool, .ellipse)

        _ = press(canvas, window, characters: "3", code: 20)
        XCTAssertEqual(canvas.tool, .mosaic)
    }

    func testCommandRDoesNotChangeTool() {
        let (canvas, window) = makeCanvas()
        let before = canvas.tool
        _ = press(canvas, window, characters: "r", code: 15, flags: .command)
        XCTAssertEqual(canvas.tool, before, "命令键不该顺手换工具")
    }
}
